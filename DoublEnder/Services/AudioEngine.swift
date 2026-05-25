import Foundation
import AppKit
import AVFoundation
import Accelerate
import Combine
import OSLog

private let logger = Logger(subsystem: "io.github.sevmorris.DoublEnder", category: "AudioEngine")

enum RecordingError: LocalizedError {
    case engineNotRunning
    case cannotAddInput
    case writerFailedToStart(String)
    case noActiveRecording
    case writerFinishedWithError(String)

    var errorDescription: String? {
        switch self {
        case .engineNotRunning:
            return "Audio engine is not running. Select an input and try again."
        case .cannotAddInput:
            return "Cannot add audio input to asset writer."
        case .writerFailedToStart(let reason):
            return "AVAssetWriter failed to start: \(reason)"
        case .noActiveRecording:
            return "Stop called without an active recording."
        case .writerFinishedWithError(let reason):
            return "Recording could not be finalized: \(reason)"
        }
    }
}

/// Hardware mic vs. aggregate/virtual device, decided by CoreAudio
/// transport type rather than fragile name matching.
private enum InputDeviceKind {
    case microphone
    case virtual
}

class AudioEngine: NSObject, ObservableObject {
    @Published var availableInputDevices: [AVCaptureDevice] = []
    @Published var selectedInputDevice: AVCaptureDevice?

    @Published var lastError: String?
    /// Current input level in dBFS (-60…0). Updated on every recorded buffer
    /// via writerQueue; reset to -60 on stop/cancel. Display-only — never
    /// affects the recording pipeline.
    @Published var rmsLevel: Float = -60
    /// True when the PCM sidecar could not be opened for this recording —
    /// crash recovery is unavailable for the current take. (M4)
    @Published var sidecarUnavailable: Bool = false
    /// True when the active input is delivering a sample rate ≤ 16 kHz,
    /// which typically indicates Bluetooth SCO (8 kHz narrowband) or another
    /// low-quality path. Does not stop recording — surfaces a UI warning. (M5)
    @Published var lowQualityInput: Bool = false

    /// True when the most recent `rebuildEngine` call reached a fully
    /// started engine successfully. The RecorderViewModel derives the
    /// on-screen device label from this — when true, the label shows the
    /// localized name of `selectedInputDeviceID`; when false, it shows
    /// "(no input)" because the engine couldn't bind / had no usable
    /// format / threw during connect or start.
    ///
    /// Starts `true` so the initial UI (before requestPermissions has
    /// driven the first rebuild) doesn't flash "(no input)". The first
    /// rebuild flips it accordingly.
    ///
    /// We deliberately do NOT compare AUHAL's reported deviceID against
    /// the intended device ID — that comparison fires intermittently on
    /// freshly-bound devices because `auAudioUnit.deviceID` lags AUHAL's
    /// actual commit (returns the sentinel 0 in the system-default path
    /// and races the propagation of system-default changes). The "engine
    /// reached .start" signal is much more reliable.
    @Published var engineHealthy: Bool = true

    /// False when `setDevice` rejected the most recent user pick because
    /// the CoreAudio device has no input streams (output-only device,
    /// disabled aggregate sub-device, etc.). We don't change the system
    /// default and don't rebuild — the previously-bound device stays
    /// active — but the UI label reads "(no input)" so the user knows
    /// their pick can't actually record. `engineHealthy` remains true
    /// because the engine itself is fine; the issue is the user's choice.
    @Published var selectedDeviceUsable: Bool = true

    /// True while `rebuildEngine` is executing, including the gap between
    /// a failed attempt and its scheduled retry. The RecorderViewModel
    /// gates RECORD on `!isRebuilding` so a tap during this transient
    /// window can't race a half-built engine. Set true at the top of
    /// rebuildEngine; set false on every exit path — success, failure,
    /// retry scheduled — so it accurately tracks "is the engine in flux
    /// right now."
    @Published var isRebuilding: Bool = false
    /// True when buffers are actively being appended to the writer (within
    /// the last ~150 ms). Drives the on-screen write-flow indicator dot.
    /// Distinct from `isRecording` (record-button state) — this only goes
    /// true when AVAssetWriterInput.append actually returns true.
    @Published var isWritingData: Bool = false

    private let aacBitRate: Int = 256_000

    private var audioEngine: AVAudioEngine?
    private var engineConfigObserver: NSObjectProtocol?
    // Always-on gentle compressor inserted upstream of the lookahead limiter.
    // Lives inside the AVAudioEngine node graph so audio actually flows
    // through it before reaching the tap. See `rebuildEngine` for the chain
    // and the parameter rationale.
    private var dynamicsProcessor: AVAudioUnitEffect?
    private var isRecording = false
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var pcmSidecar: PCMSidecar?
    private var writerFrameCount: Int64 = 0
    private let writerLock = NSLock()
    private var currentTapFormat: AVAudioFormat?
    /// uniqueID → kind, rebuilt on each device refresh so the picker
    /// doesn't re-query CoreAudio on every SwiftUI render.
    private var deviceKindCache: [String: InputDeviceKind] = [:]
    private var consecutiveWriteErrors = 0
    private let writeErrorThreshold = 5
    // First-buffer signalling. Reset on every rebuildEngine; signalled
    // exactly once by the tap closure on its first invocation after that.
    // startRecording briefly blocks on the semaphore so the writer never
    // opens before the engine is actually delivering audio — without this,
    // a tap-RECORD-then-tap-STOP within ~50–200 ms of launch produces a
    // zero-frame file and surfaces a misleading "empty file" error.
    private let firstBufferLock = NSLock()
    private var firstBufferDelivered = false
    private let firstBufferSemaphore = DispatchSemaphore(value: 0)
    private var limiter: LookaheadLimiter?
    // Conditional resampler / mono downmixer that bridges the tap format to
    // an AAC-friendly mono PCM stream. Nil for WAV at the hardware rate.
    private var encoderConverter: AVAudioConverter?
    private var encoderFormat: AVAudioFormat?
    // First-five PTS log — flips on at startRecording, helps surface
    // timestamp problems if the writer ever rejects samples again.
    private var ptsLogCount = 0

    /// Bounded FIFO of unprocessed tap buffers held when the writer briefly
    /// reports `isReadyForMoreMediaData == false`. AVAssetWriter with
    /// `expectsMediaDataInRealTime = true` runs an internal sync ~every 15
    /// seconds from `startSession` — during the sync window (sub-millisecond
    /// to a few ms) the input ring is closed. Without this queue, a buffer
    /// that arrived inside the window would be dropped (the legacy
    /// "transient encoder backpressure" path), producing a ~21 ms hole in
    /// the file at every 15s boundary — the source of the periodic
    /// "double-tap / stutter" artifact reported in field testing.
    ///
    /// We hold buffers in their original tap format (multi-channel, hardware
    /// rate) so the limiter and converter still see them in capture order at
    /// drain time. PTS stays monotonic because `writerFrameCount` only
    /// advances on successful append, regardless of which callback the
    /// append happens on.
    ///
    /// Capacity covers ~2.1 s of audio at 1024 samples / 48 kHz — orders of
    /// magnitude more than the longest backpressure window we've ever
    /// observed. If we ever do hit the cap, we drop the OLDEST entry; PTS
    /// continuity is preserved because we don't fabricate replacement
    /// frames. Reaching the cap means the writer has been wedged for ~2 s,
    /// which is a real failure that the consecutiveWriteErrors path will
    /// already be catching.
    private var pendingTapBuffers: [AVAudioPCMBuffer] = []
    private static let maxPendingTapBuffers = 100

    // Serial queue for all AVAssetWriter / PCMSidecar work. Moving this
    // off the AVAudioEngine tap thread eliminates NSLock, malloc, and file
    // I/O from the real-time audio callback.
    private let writerQueue = DispatchQueue(
        label: "io.github.sevmorris.DoublEnder.writer",
        qos: .userInitiated
    )
    /// Scheduled "clear write indicator" task; cancelled and re-scheduled on
    /// every successful writer append so isWritingData only flips to false
    /// when buffers stop arriving for 150 ms.
    private var writeIndicatorClearWork: DispatchWorkItem?

    /// Called on the main thread when a device disconnects mid-recording.
    /// RecorderViewModel sets this so it can run the full stop / notification
    /// / upload path rather than having AudioEngine duplicate that logic.
    var onDisconnectedDuringRecording: (() -> Void)?

    /// Called on the main thread when a USB input device appears in the
    /// system while the app is running. Fires only for genuinely new UIDs;
    /// the engine seeds its known-UID set on its first device refresh, so
    /// the launch-time population does NOT trigger this callback.
    /// RecorderViewModel sets this to offer a "switch input?" prompt.
    var onNewUSBDeviceDetected: ((AVCaptureDevice) -> Void)?

    /// Snapshot of every input device UID present at last `refreshDevices`,
    /// used to diff against the next refresh and detect newly-arrived USB
    /// devices for the hot-plug prompt.
    private var knownInputDeviceUIDs: Set<String> = []
    /// First `refreshDevices` seeds `knownInputDeviceUIDs` without firing
    /// any "new device" callbacks — the launch-time device population is
    /// not a "new" arrival from the user's perspective.
    private var hasSeededKnownDevices = false
    /// Held strong reference to the CoreAudio device-list listener block so
    /// it can be removed in deinit. `AudioObjectAddPropertyListenerBlock`
    /// retains the block too, but we need to pass the same reference back
    /// to `AudioObjectRemovePropertyListenerBlock`.
    private var deviceListBlock: AudioObjectPropertyListenerBlock?

    // AAC-LC's allowed input sample rates per the standard. Anything else
    // makes the encoder reject samples with "Cannot Encode Media."
    private static let aacSupportedSampleRates: Set<Double> = [
        8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 64000, 88200, 96000
    ]
    private static let aacFallbackSampleRate: Double = 48000

    private static func aacSampleRate(matching rate: Double) -> Double {
        aacSupportedSampleRates.contains(rate) ? rate : aacFallbackSampleRate
    }

    override init() {
        super.init()
        refreshDevices()
        // Refresh the device list whenever the system wakes or the app comes
        // to front — devices plugged in while DoublEnder was in the background
        // otherwise stay hidden in the picker until something else triggers a
        // config-change notification.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRefreshTrigger),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleRefreshTrigger),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        // Live device-add/remove notifications. Without this, USB devices
        // that appear while the app is foregrounded — and while the engine
        // is running on an unrelated input — go undetected until the next
        // app-activation or wake notification, missing the moment the user
        // expects the new mic to be picked up.
        installDeviceListListener()
    }

    deinit {
        removeDeviceListListener()
    }

    /// Register a CoreAudio listener on the system-wide device list so that
    /// `refreshDevices` runs whenever any audio device is added or removed
    /// anywhere on the system. The listener block dispatches to the main
    /// queue before touching engine state, matching every other entry into
    /// `refreshDevices` (notification observers, engine config change).
    private func installDeviceListListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshDevices() }
        }
        deviceListBlock = block
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func removeDeviceListListener() {
        guard let block = deviceListBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        deviceListBlock = nil
    }

    @objc private func handleRefreshTrigger() {
        guard !isRecording else { return }
        refreshDevices()
    }

    /// Run `engine` briefly with a minimal input→sink chain so AUHAL commits
    /// the bound device's HW stream description before the caller reads
    /// `inputNode.outputFormat` for the real chain. Returns when the sink
    /// has received its first buffer (proof the device is delivering audio)
    /// or after a 250 ms safety timeout — whichever comes first. Any
    /// AVFoundation NSException raised during the warm-up is caught and
    /// logged; the function returns and the caller proceeds with whatever
    /// format `outputFormat` reports.
    ///
    /// Caller must NOT have built any other chain on `engine` yet.
    private func forceAUHALCommit(on engine: AVAudioEngine) {
        let firstBufferSem = DispatchSemaphore(value: 0)
        var signaled = false
        let signalLock = NSLock()
        let sink = AVAudioSinkNode { _, _, _ in
            signalLock.lock()
            if !signaled {
                signaled = true
                firstBufferSem.signal()
            }
            signalLock.unlock()
            return noErr
        }
        engine.attach(sink)

        let connectExc = ExceptionCatcher.try({
            engine.connect(engine.inputNode, to: sink, format: nil)
        })
        if let exc = connectExc {
            logger.warning("AUHAL warm-up connect failed: \(exc.reason ?? exc.name.rawValue, privacy: .public)")
            engine.detach(sink)
            return
        }

        let startExc = ExceptionCatcher.try({
            do {
                try engine.start()
            } catch {
                logger.warning("AUHAL warm-up start failed: \(error.localizedDescription, privacy: .public)")
            }
        })
        if let exc = startExc {
            logger.warning("AUHAL warm-up start NSException: \(exc.reason ?? exc.name.rawValue, privacy: .public)")
        }

        // Wait for first buffer (proof AUHAL pushed data through) or the
        // safety timeout. The vast majority of devices commit inside 30–50 ms;
        // 250 ms is the same window startRecording uses for first-buffer wait.
        _ = firstBufferSem.wait(timeout: .now() + .milliseconds(250))

        engine.stop()
        // disconnect before detach so the input bus is released cleanly.
        engine.disconnectNodeInput(sink)
        engine.detach(sink)
    }

    /// Build Apple's `kAudioUnitSubType_DynamicsProcessor` (the audio unit
    /// behind what the spec colloquially calls "AVAudioUnitDynamicsProcessor"
    /// — there is no Swift class by that literal name; you instantiate it via
    /// `AVAudioUnitEffect` with the right `AudioComponentDescription`).
    ///
    /// The returned effect is NOT yet attached to an engine, and NO parameters
    /// have been set. Setting AU parameters before the unit is attached to a
    /// host has been observed to leave Apple's dynamics processor in a state
    /// where `Initialize()` later fails with -10875. Parameters live in
    /// `configureDynamicsProcessor(_:)` and are applied post-attach.
    private func makeDynamicsProcessor() -> AVAudioUnitEffect {
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return AVAudioUnitEffect(audioComponentDescription: desc)
    }

    /// Apply the always-on transparent-leveler parameters to a dynamics
    /// processor that has already been attached to an engine.
    ///
    /// • Threshold: -20 dBFS — compression starts well below clipping; quiet
    ///   speech sits below threshold and is untouched.
    /// • Head room: 10 dB — soft-knee region above threshold; smooths the
    ///   onset of compression so transients don't pump.
    /// • Attack: 1 ms — fast enough to catch plosives, slow enough to keep
    ///   sibilance natural.
    /// • Release: 100 ms — long enough to avoid pumping on speech rhythm.
    /// • Overall gain: 0 dB — no make-up gain; the limiter downstream is the
    ///   only place we re-touch level.
    private func configureDynamicsProcessor(_ dyn: AVAudioUnitEffect) {
        let au = dyn.audioUnit
        AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold,   kAudioUnitScope_Global, 0, -20,   0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_HeadRoom,    kAudioUnitScope_Global, 0,  10,   0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_AttackTime,  kAudioUnitScope_Global, 0,   0.001, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0,   0.100, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0,   0,   0)
    }

    func start() {
        if audioEngine?.isRunning == true { return }
        rebuildEngine(with: nil)
    }
    
    /// Max retries for the AUHAL "Input HW format and tap format not matching"
    /// race. Each retry waits `auhalRetryDelay` to give CoreAudio more time
    /// to finalize device-format negotiation. Three attempts × 150ms covers
    /// a generous window without making a real failure feel hung.
    private static let auhalMaxRetries = 3
    private static let auhalRetryDelay: DispatchTimeInterval = .milliseconds(150)

    private func rebuildEngine(
        with deviceID: AudioDeviceID? = nil,
        intendedDeviceID: AudioDeviceID? = nil,
        attempt: Int = 1
    ) {
        // Mark the engine as in-flux for the duration of this call.
        // Every exit path below (success, hard failure, retry-scheduled)
        // is responsible for flipping this back to false. Doing it here
        // at the top covers the first attempt; recursive retries from
        // the connect-race path re-enter this function and re-set it.
        DispatchQueue.main.async { self.isRebuilding = true }

        if let obs = engineConfigObserver {
            NotificationCenter.default.removeObserver(obs)
            engineConfigObserver = nil
        }
        if let engine = audioEngine {
            engine.stop()
            // Tap lives on the dynamics-processor node when the chain is up;
            // fall back to inputNode for safety on engines that never reached
            // a fully built state.
            if let dyn = dynamicsProcessor {
                dyn.removeTap(onBus: 0)
                engine.detach(dyn)
            } else {
                engine.inputNode.removeTap(onBus: 0)
            }
            audioEngine = nil
            dynamicsProcessor = nil
        }
        // Clear `currentTapFormat` BEFORE any early-return path can fire.
        // startRecording's `guard let tapFormat = currentTapFormat` is the
        // only thing standing between a failed rebuild and the writer
        // opening on a dead engine — leaving the previous build's format
        // here would let recording proceed against a torn-down engine and
        // silently produce empty files. The format gets re-set further
        // down only after a fully successful rebuild reaches the chain.
        currentTapFormat = nil

        let newEngine = AVAudioEngine()

        // Reset first-buffer state for the fresh engine. Drain any stale
        // semaphore signal from a prior rebuild so the next startRecording
        // waits only for THIS engine's first tap callback, not a leftover
        // signal from the previous one.
        firstBufferLock.lock()
        while firstBufferSemaphore.wait(timeout: .now()) == .success {}
        firstBufferDelivered = false
        firstBufferLock.unlock()

        if let deviceID = deviceID {
            do {
                // Must be called before accessing inputNode for the first time or before prepare
                try newEngine.inputNode.auAudioUnit.setDeviceID(deviceID)
            } catch {
                logger.error("Failed to set device ID: \(error.localizedDescription, privacy: .public)")
            }
            // AUHAL warm-up. After setDeviceID, AUHAL's CoreAudio-side device
            // binding updates synchronously but AVAudioEngine's cached view of
            // outputFormat(forBus:) does NOT refresh until the inputNode is
            // actually pulled — leaving the chain we build below using a
            // format that doesn't match what the hardware actually delivers.
            // The original fix was install-tap-then-remove-tap, which is
            // enough to surface a format on built-in mics (always-on, already
            // committed in CoreAudio) but NOT enough on freshly-bound USB
            // devices: AUHAL hasn't fully committed the device's HW stream
            // description yet, and the connect() in the real chain later
            // trips "Input HW format and tap format not matching" — even
            // though outputFormat reads a plausible-looking format.
            //
            // Force AUHAL to commit by running the engine briefly with a
            // minimal input→sink chain. The sink's render block firing once
            // proves AUHAL has pushed real data through and the HW stream
            // description is now stable. Stop + tear down the warm-up chain
            // before building the real one.
            forceAUHALCommit(on: newEngine)
        }

        let inputNode = newEngine.inputNode
        // outputFormat (not inputFormat) is what the inputNode emits to
        // downstream nodes — i.e. the format that any subsequent connect()
        // must agree with. On most macOS mics input/output formats are the
        // same, but on devices where they diverge, giving connect() the
        // wrong one makes the downstream AU fail to initialize with -10875.
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        guard nativeFormat.channelCount > 0, nativeFormat.sampleRate > 0 else {
            let message = "Selected input device reports no usable format (channels=\(nativeFormat.channelCount), rate=\(nativeFormat.sampleRate))."
            DispatchQueue.main.async {
                self.lastError = message
                self.engineHealthy = false
                self.isRebuilding = false
            }
            return
        }

        // M5: flag sample rates ≤ 16 kHz — almost always Bluetooth SCO (8 kHz)
        // or a misconfigured device. Doesn't block recording; just surfaces the
        // warning so the user can switch to a better input.
        let isLowQuality = nativeFormat.sampleRate <= 16_000
        if isLowQuality {
            logger.warning("Input rate \(nativeFormat.sampleRate, privacy: .public) Hz — possible Bluetooth SCO or low-quality device.")
        }
        DispatchQueue.main.async { self.lowQualityInput = isLowQuality }

        // Use the inputNode's own outputFormat as the chain format.
        //
        // AVAudioEngine standardizes input-bus output to Float32 deinterleaved
        // at the device's native sample rate and channel count — exactly the
        // canonical format the dynamics processor (and every other Apple AU
        // effect) requires. We previously rebuilt our own AVAudioFormat with
        // matching SR / channels / Float32-deinterleaved, on the theory that
        // an explicit format eliminates connect() mismatches. The opposite
        // turned out to be true: AVAudioEngine.connect compares the FULL
        // stream description, INCLUDING channel layout. The inputNode's
        // outputFormat carries the device's channel layout (e.g.
        // kAudioChannelLayoutTag_Mono for mono); the format produced by
        // AVAudioFormat(commonFormat:sampleRate:channels:interleaved:) has
        // no layout at all. Two formats that look identical in every visible
        // field then fail with "Input HW format and tap format not matching"
        // — a reliable repro on USB mics whose layout AUHAL fills in
        // explicitly. Using inputNode.outputFormat directly carries the
        // layout through and the validation passes.
        let chainFormat = nativeFormat
        currentTapFormat = chainFormat

        // ── Audio graph ──────────────────────────────────────────────────────
        //
        //  inputNode ─→ dynamicsProcessor ─→ AVAudioSinkNode (no-op terminator)
        //                       │
        //                       └─→ tap (post-compression buffers)
        //                              ├─ RMS meter
        //                              └─ writerQueue → LookaheadLimiter
        //                                            → AVAudioConverter
        //                                            → PCMSidecar + AVAssetWriter
        //
        // We terminate the graph with AVAudioSinkNode rather than mainMixerNode
        // because DoublEnder never plays audio back through the speakers — and
        // routing through mainMixerNode/outputNode activates the output
        // hardware path, which on first launch can leave AVAudioEngineGraph
        // init failing with -10875 (IsFormatSampleRateAndChannelCountValid on
        // outputHWFormat) before the system output device has finished
        // enumeration. Sink-terminating avoids the output hardware entirely.
        //
        // The dynamics processor is engine-scoped (lives across recordings)
        // so the meter reads post-compression at all times. The tap is
        // installed on the processor's output bus.
        //
        // Order matters: attach → configure (set parameters) → connect →
        // installTap → prepare → start. Configuring before attach left the
        // dynamics processor in a state where Initialize() failed (-10875).
        let dynamics = makeDynamicsProcessor()
        newEngine.attach(dynamics)
        configureDynamicsProcessor(dynamics)

        // AVAudioEngine.connect raises NSException (NOT NSError) out of
        // AVAudioIONodeImpl::SetOutputFormat when the format passed disagrees
        // with what the input node can actually deliver. Reliably triggered
        // when binding to a freshly-arrived USB device whose AUHAL format
        // negotiation hasn't fully settled — the warm-up tap above gets a
        // best-effort refresh but CoreAudio sometimes needs another beat to
        // commit the device's real stream description. The exception reason
        // is "Input HW format and tap format not matching" in that case.
        //
        // Swift's do/try/catch can't catch NSException; without this wrapper
        // the throw rides straight to __cxa_throw → std::terminate → abort.
        if let exc = ExceptionCatcher.try({
            newEngine.connect(inputNode, to: dynamics, format: chainFormat)
        }) {
            let postFailFormat = newEngine.inputNode.outputFormat(forBus: 0)
            let reason = exc.reason ?? ""
            // Race-with-AUHAL signature: the format we just queried doesn't
            // match what the IO node will actually deliver. Retry the whole
            // rebuild after a brief delay so CoreAudio can finish negotiation.
            let isFormatRace = reason.contains("format") && reason.contains("matching")
            if isFormatRace && attempt < Self.auhalMaxRetries {
                logger.info(
                    "connect raced AUHAL device negotiation (attempt \(attempt, privacy: .public)/\(Self.auhalMaxRetries, privacy: .public)); retrying after delay"
                )
                // Detach what we attached so far before the new engine spins
                // up — leaving an orphaned dynamics on a stopped engine is
                // harmless but noisy in instruments.
                newEngine.detach(dynamics)
                // isRebuilding stays true across the 150 ms gap to the
                // retry — the recursive rebuildEngine call re-asserts it
                // at the top, and either succeeds (sets false) or fails
                // again (sets false on the final-failure branch). RECORD
                // stays disabled throughout the whole retry chain.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.auhalRetryDelay) { [weak self] in
                    self?.rebuildEngine(with: deviceID, intendedDeviceID: intendedDeviceID, attempt: attempt + 1)
                }
                return
            }
            logger.error(
                "connect(input → dynamics) NSException: \(exc.name.rawValue, privacy: .public) — \(reason, privacy: .public). chainFormat: \(chainFormat, privacy: .public) — inputNode.outputFormat: \(postFailFormat, privacy: .public)"
            )
            let message = "Could not bind to the selected input. \(reason.isEmpty ? exc.name.rawValue : reason)"
            DispatchQueue.main.async {
                self.lastError = message
                self.engineHealthy = false
                self.isRebuilding = false
            }
            return
        }

        // Engine-scoped no-op sink. The render block has to be present but
        // can immediately return noErr — the audio it would otherwise consume
        // is already being captured by the tap installed on `dynamics` below.
        let sink = AVAudioSinkNode { _, _, _ in noErr }
        newEngine.attach(sink)
        if let exc = ExceptionCatcher.try({
            newEngine.connect(dynamics, to: sink, format: chainFormat)
        }) {
            logger.error(
                "connect(dynamics → sink) NSException: \(exc.name.rawValue, privacy: .public) — \(exc.reason ?? "no reason", privacy: .public)"
            )
            let message = "Could not build audio chain. \(exc.reason ?? exc.name.rawValue)"
            DispatchQueue.main.async {
                self.lastError = message
                self.engineHealthy = false
                self.isRebuilding = false
            }
            return
        }

        dynamicsProcessor = dynamics

        dynamics.installTap(onBus: 0, bufferSize: 1024, format: chainFormat) { [weak self] (buffer, _) in
            guard let self = self else { return }

            // Signal first-buffer arrival exactly once per engine lifetime so
            // startRecording can stop waiting. Fast path: an unsynchronised
            // bool read on every subsequent call — benign because the only
            // transition is false→true and a momentarily-stale false just
            // costs one extra (idempotent) lock acquisition.
            if !self.firstBufferDelivered {
                self.firstBufferLock.lock()
                let firstTime = !self.firstBufferDelivered
                if firstTime { self.firstBufferDelivered = true }
                self.firstBufferLock.unlock()
                if firstTime { self.firstBufferSemaphore.signal() }
            }

            // Meter: compute RMS on every buffer so the level display is live
            // at all times, not only during recording. vDSP_rmsqv is pure
            // math — RT-safe. The main-queue dispatch is the only non-RT
            // operation; the overhead is negligible at 44–48 calls/sec.
            if let data = buffer.floatChannelData?[0] {
                var rms: Float = 0
                vDSP_rmsqv(data, 1, &rms, vDSP_Length(buffer.frameLength))
                let db = rms > 1e-9 ? 20.0 * log10f(rms) : -60
                DispatchQueue.main.async { [weak self] in
                    self?.rmsLevel = max(-60, min(0, db))
                }
            }

            // Skip the copy+dispatch overhead while not recording.
            guard self.isRecording else { return }

            // Copy audio data before the engine can reclaim the buffer.
            // AVAudioPCMBuffer alloc + memcpy is the minimum work needed on
            // the RT thread; everything else (NSLock, conversion, file I/O,
            // CMSampleBuffer construction) runs on writerQueue below.
            let fmt = buffer.format
            let frameLength = buffer.frameLength
            guard let copy = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameLength) else { return }
            copy.frameLength = frameLength
            if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
                for c in 0..<Int(fmt.channelCount) {
                    memcpy(dst[c], src[c], Int(frameLength) * MemoryLayout<Float>.size)
                }
            }
            self.writerQueue.async { [weak self] in
                self?.appendBufferToWriter(copy)
            }
        }

        // newEngine.prepare() can also raise NSException on AUHAL format
        // disputes — same wrapper rationale as the connects above.
        if let exc = ExceptionCatcher.try({ newEngine.prepare() }) {
            logger.error(
                "engine.prepare NSException: \(exc.name.rawValue, privacy: .public) — \(exc.reason ?? "no reason", privacy: .public)"
            )
            let message = "Could not prepare audio engine. \(exc.reason ?? exc.name.rawValue)"
            DispatchQueue.main.async {
                self.lastError = message
                self.engineHealthy = false
                self.isRebuilding = false
            }
            return
        }

        // engine.start can fail two ways: NSError (try/catch path) for the
        // -10875 family, AND NSException for format disputes that surface
        // out of Start() in some AUHAL versions. Catch both.
        var startNSError: Error?
        let startExc = ExceptionCatcher.try({
            do {
                try newEngine.start()
            } catch {
                startNSError = error
            }
        })
        if let exc = startExc {
            let postFailFormat = newEngine.inputNode.outputFormat(forBus: 0)
            logger.error(
                "engine.start NSException: \(exc.name.rawValue, privacy: .public) — \(exc.reason ?? "no reason", privacy: .public). chainFormat: \(chainFormat, privacy: .public) — inputNode.outputFormat: \(postFailFormat, privacy: .public)"
            )
            let message = "Failed to start audio engine. \(exc.reason ?? exc.name.rawValue)"
            DispatchQueue.main.async {
                self.lastError = message
                self.engineHealthy = false
                self.isRebuilding = false
            }
            return
        }
        if let error = startNSError {
            // Capture format snapshots so the unified log shows the format we
            // wired the chain with vs. what the inputNode actually reports now.
            // If they differ, we hit the AUHAL setDeviceID staleness window
            // and the warm-up tap didn't take. If they match, -10875 came
            // from something else (e.g. channel count > 2 on the dynamics
            // processor) and we'll know to look further.
            let postFailFormat = newEngine.inputNode.outputFormat(forBus: 0)
            logger.error(
                "engine.start failed (-10875 family): connect-time format \(chainFormat, privacy: .public) — post-failure inputNode.outputFormat \(postFailFormat, privacy: .public) — error: \(error.localizedDescription, privacy: .public)"
            )
            let message = "Failed to start audio engine: \(error.localizedDescription)"
            DispatchQueue.main.async {
                self.lastError = message
                self.engineHealthy = false
                self.isRebuilding = false
            }
            return
        }

        self.audioEngine = newEngine
        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: newEngine,
            queue: .main
        ) { [weak self] _ in self?.handleEngineConfigurationChange() }

        // Verify the rebuild landed on the device the caller intended.
        //
        // `setSystemDefaultInputDevice` returns noErr for some virtual
        // devices (ZoomAudioDevice, Descript Loopback Recorder, others)
        // even though CoreAudio quietly refuses the change — the system
        // default property stays at the previous value, and AUHAL binds
        // the new engine to that previous device. The meter and writer
        // then capture from the wrong source. Pre-check via
        // `kAudioDevicePropertyStreams` can't filter these out: they
        // honestly report input streams with channels.
        //
        // The reliable detector is to re-read the system default after
        // the rebuild and compare to what the caller asked for. If they
        // differ, CoreAudio silently rejected the switch. The engine is
        // still on the previous (working) device — no restore needed —
        // but the user's pick was not honoured, so flip `selectedDeviceUsable`
        // false. The VM's computed label then reads "(no input)" and the
        // RECORD button is disabled via the existing `canStartRecording`
        // gate (which AND-s on `selectedDeviceUsable`).
        //
        // `engineHealthy` stays true because the engine itself is fine;
        // it's the user's pick that's unusable.
        let resolvedSystemDefault = currentSystemDefaultInputDevice()
        let silentFallback: Bool
        if let intended = intendedDeviceID {
            silentFallback = (resolvedSystemDefault ?? 0) != intended
            if silentFallback {
                logger.warning(
                    "CoreAudio silently rejected setSystemDefaultInputDevice — intended=\(intended, privacy: .public) but systemDefault=\(resolvedSystemDefault ?? 0, privacy: .public). Engine remains on the previously bound device."
                )
            }
        } else {
            silentFallback = false
        }

        // Engine reached .start without throwing — that's "healthy" enough
        // to drive the UI label.
        DispatchQueue.main.async {
            self.engineHealthy = true
            self.isRebuilding = false
            if silentFallback {
                self.selectedDeviceUsable = false
            }
        }
    }

    /// Called on every successful AVAssetWriterInput.append. Bumps
    /// isWritingData true (if needed) and reschedules the "clear after
    /// 150 ms" task so the indicator stays lit while buffers keep arriving
    /// and goes dark only when the flow actually stops.
    private func markDataFlowing() {
        if !isWritingData { isWritingData = true }
        writeIndicatorClearWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.isWritingData = false
        }
        writeIndicatorClearWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: item)
    }

    private func handleEngineConfigurationChange() {
        guard audioEngine != nil else { return }
        logger.info("AVAudioEngine configuration changed (isRecording: \(self.isRecording, privacy: .public))")

        if isRecording {
            // Recording in progress. Setting isRecording = false prevents
            // new buffers from being dispatched to writerQueue. The VM's
            // onDisconnectedDuringRecording callback then calls its own
            // stopRecording, which drains writerQueue and finalizes the
            // writer — ensuring notification and Cloud upload happen too.
            isRecording = false
            onDisconnectedDuringRecording?()
        } else {
            // Not recording — rebuild silently with the system default device.
            // This handles both spurious startup notifications and real device
            // changes while idle. If the rebuild fails, rebuildEngine sets
            // lastError through its own error paths.
            rebuildEngine(with: nil)
            refreshDevices()
        }
    }
    
    func refreshDevices() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        // Filter out macOS's internal "CADefaultDeviceAggregate-*" devices.
        // These are wrapper aggregates CoreAudio auto-creates around the
        // current system default whenever AUHAL needs to bind via the
        // default-device path. They have user-visible names like
        // "CADefaultDeviceAggregate-84517-1" that mean nothing to the user;
        // picking one is functionally a no-op (it re-points at whatever the
        // real default already is) but visually confusing in the picker.
        let visibleDevices = session.devices.filter {
            !$0.localizedName.hasPrefix("CADefaultDeviceAggregate")
        }
        self.availableInputDevices = visibleDevices
        deviceKindCache = Dictionary(
            uniqueKeysWithValues: visibleDevices.map { ($0.uniqueID, classify($0)) }
        )

        // Diff against the previous device list to detect hot-plug arrivals.
        // The first pass after init seeds the known-set without firing any
        // callbacks — launch-time device population is not a "new arrival"
        // from the user's perspective and is handled by the VM's USB-on-
        // launch policy separately. Subsequent refreshes (from the CoreAudio
        // listener, app activation, system wake, or engine config change)
        // fire onNewUSBDeviceDetected for any USB UID that wasn't there before.
        //
        // Order matters: update `knownInputDeviceUIDs` BEFORE firing the
        // callback. The VM's handler runs an app-modal NSAlert which spins a
        // nested event loop, and any re-entrant refreshDevices that lands
        // during that loop (app activation, another hot-plug, engine config
        // change) would otherwise see the same UID as "new" again and stack
        // duplicate prompts.
        // Diff against the filtered list — we don't want to fire the
        // hot-plug callback for macOS-internal aggregates appearing
        // (which happens every time CoreAudio rebuilds them under us).
        let currentUIDs = Set(visibleDevices.map { $0.uniqueID })
        if hasSeededKnownDevices {
            let newUIDs = currentUIDs.subtracting(knownInputDeviceUIDs)
            knownInputDeviceUIDs = currentUIDs
            for uid in newUIDs {
                if let device = visibleDevices.first(where: { $0.uniqueID == uid }),
                   isUSBDevice(device) {
                    onNewUSBDeviceDetected?(device)
                }
            }
        } else {
            hasSeededKnownDevices = true
            knownInputDeviceUIDs = currentUIDs
        }

        if selectedInputDevice == nil {
            selectedInputDevice = AVCaptureDevice.default(for: .audio)
        }
    }

    /// True if `device` is connected via USB transport per CoreAudio.
    /// Hardware mics built into the Mac, Bluetooth headsets, Thunderbolt
    /// interfaces, and aggregate/virtual devices all return false.
    func isUSBDevice(_ device: AVCaptureDevice) -> Bool {
        guard let id = audioDeviceID(forUID: device.uniqueID),
              let transport = transportType(for: id) else {
            return false
        }
        return transport == kAudioDeviceTransportTypeUSB
    }

    /// Currently-present USB input devices, in discovery order.
    func usbInputDevices() -> [AVCaptureDevice] {
        availableInputDevices.filter { isUSBDevice($0) }
    }

    /// True if `device` is the Mac's built-in hardware input per CoreAudio
    /// transport. MacBook built-in mics return true; USB / Bluetooth /
    /// aggregate / virtual devices return false. RecorderViewModel uses
    /// this at launch to seed the engine with the Mac's native hardware
    /// input — a deterministic starting state independent of saved
    /// preferences or currently-attached USB devices.
    func isBuiltInDevice(_ device: AVCaptureDevice) -> Bool {
        guard let id = audioDeviceID(forUID: device.uniqueID),
              let transport = transportType(for: id) else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBuiltIn
    }

    /// First built-in hardware input device, or nil on Macs that have none
    /// (Mac mini, Mac Studio, etc.). Returns in discovery order — there is
    /// almost never more than one on a single machine.
    func builtInInputDevice() -> AVCaptureDevice? {
        availableInputDevices.first { isBuiltInDevice($0) }
    }

    /// Hardware mics vs. aggregate/virtual devices, preserving discovery
    /// order within each group. Driven by the cache built in
    /// `refreshDevices()`, with a lazy fallback for safety.
    func groupedInputDevices() -> (microphones: [AVCaptureDevice], virtual: [AVCaptureDevice]) {
        var microphones: [AVCaptureDevice] = []
        var virtual: [AVCaptureDevice] = []
        for device in availableInputDevices {
            let kind: InputDeviceKind
            if let cached = deviceKindCache[device.uniqueID] {
                kind = cached
            } else {
                kind = classify(device)
                deviceKindCache[device.uniqueID] = kind
            }
            if kind == .virtual {
                virtual.append(device)
            } else {
                microphones.append(device)
            }
        }
        return (microphones, virtual)
    }
    
    /// Begin a recording. The AVAssetWriter streams samples directly to
    /// `fileURL` — there is no temp file, no move step on stop. A raw-PCM
    /// crash-recovery sidecar is mirrored alongside it (see `PCMSidecar`).
    /// `format` selects the container/codec; `notes` is written as the
    /// file's description metadata tag.
    func startRecording(to fileURL: URL, format: OutputFormat = .aac, notes: String = "") throws {
        guard let tapFormat = currentTapFormat else {
            throw RecordingError.engineNotRunning
        }

        // First-buffer wait. On a freshly-built engine (first launch, or
        // post device hot-swap) engine.start() returns before the tap has
        // actually fired — there's a 50–200 ms cold-start window where
        // AUHAL is opening the device and the dynamics-processor + sink
        // graph is settling its first render cycle. If the writer opens
        // and the user hits STOP inside that window, the file finalises
        // with zero frames and we'd surface a misleading "empty file"
        // error. Block here briefly so the writer never opens until the
        // engine is delivering audio. 250 ms covers typical first-launch
        // warmup with margin; past that, the zero-frame guard in
        // stopRecording catches the residue with a clearer message.
        if !firstBufferDelivered {
            _ = firstBufferSemaphore.wait(timeout: .now() + .milliseconds(250))
        }

        // AVAssetWriter refuses to start if the file already exists.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            logger.warning("Output file already exists — removing: \(fileURL.lastPathComponent, privacy: .public)")
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                // A locked or in-use file (iCloud sync, other app) gives a
                // confusing "file exists" error from AVAssetWriter — surface
                // the real reason instead.
                throw RecordingError.writerFailedToStart(
                    "Could not remove existing file '\(fileURL.lastPathComponent)': \(error.localizedDescription)"
                )
            }
        }

        // Pick a sample rate the encoder will actually accept. AAC silently
        // rejects samples ("Cannot Encode Media") when fed PCM at rates
        // outside its standard set — a real failure mode on USB interfaces
        // that default to 96 / 176.4 / 192 kHz. WAV passes the hardware
        // rate through untouched.
        let encoderRate: Double
        switch format {
        case .aac: encoderRate = Self.aacSampleRate(matching: tapFormat.sampleRate)
        case .wav: encoderRate = tapFormat.sampleRate
        }
        if encoderRate != tapFormat.sampleRate {
            logger.info("Hardware rate \(tapFormat.sampleRate, privacy: .public) Hz isn't AAC-compatible — converting to \(encoderRate, privacy: .public) Hz.")
        }

        // The converter folds multi-channel-to-mono and resamples (when
        // needed) in a single pass before samples reach the writer.
        guard let encFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: encoderRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecordingError.writerFailedToStart("could not build encoder PCM format")
        }
        let converter = AVAudioConverter(from: tapFormat, to: encFormat)

        let fileType: AVFileType
        let outputSettings: [String: Any]
        switch format {
        case .aac:
            fileType = .m4a
            outputSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: encoderRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: aacBitRate
            ]
        case .wav:
            // 24-bit signed integer PCM — the professional-audio standard for
            // uncompressed delivery. Universally compatible with podcast/DAW
            // tooling, ~25% smaller than int32 with no audible loss. The
            // writer converts the float32 CMSampleBuffers we supply down to
            // int24 internally; AVAudioConverter is not needed because
            // AVAssetWriter's WAV path handles float→int packing itself.
            //
            // The PCM sidecar (PCMSidecar.swift) stays at 32-bit float — it
            // is only used as a crash-recovery fallback when the main writer
            // never finalizes, and float32 preserves the source samples
            // verbatim with no requantization loss. Recovered WAVs from the
            // sidecar are written as 32-bit float; the main WAV is 24-bit int.
            fileType = .wav
            outputSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: encoderRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        }

        let writer = try AVAssetWriter(outputURL: fileURL, fileType: fileType)

        // Description metadata (Notes field). M4A honors this in the moov
        // atom; for WAV the writer may drop it depending on the container.
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierDescription
            item.value = trimmedNotes as NSString
            writer.metadata = [item]
        }

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw RecordingError.cannotAddInput
        }
        writer.add(input)

        guard writer.startWriting() else {
            let reason = writer.error?.localizedDescription ?? "unknown error"
            throw RecordingError.writerFailedToStart(reason)
        }
        writer.startSession(atSourceTime: .zero)

        // Mirror the post-limiter, post-conversion mono stream so an
        // unfinalized .m4a can still be recovered. A nil sidecar (I/O
        // failure) is non-fatal — the recording proceeds without the
        // safety net. Sidecar rate matches the writer so playback parity
        // is preserved on recovery.
        let sidecar = PCMSidecar(mainOutput: fileURL, sampleRate: encoderRate, channels: 1)
        // M4: flag when the safety net is unavailable so the UI can warn.
        let sidecarMissing = sidecar == nil
        if sidecarMissing {
            logger.warning("PCMSidecar init failed — this recording has no crash-recovery safety net.")
        }
        DispatchQueue.main.async { self.sidecarUnavailable = sidecarMissing }

        writerLock.lock()
        assetWriter = writer
        assetWriterInput = input
        pcmSidecar = sidecar
        writerFrameCount = 0
        limiter = LookaheadLimiter(sampleRate: tapFormat.sampleRate, channels: Int(tapFormat.channelCount))
        encoderConverter = converter
        encoderFormat = encFormat
        ptsLogCount = 0
        consecutiveWriteErrors = 0
        // Stale entries from a previous take would carry the wrong sample
        // format and would never be valid input for this writer.
        pendingTapBuffers.removeAll()
        writerLock.unlock()

        isRecording = true
    }

    /// Abort the in-progress recording without finalizing. `cancelWriting()`
    /// deletes the partial output file. Used by the "Quit Without Saving"
    /// confirmation path.
    func cancelRecording(completion: @escaping () -> Void) {
        isRecording = false
        DispatchQueue.main.async {
            self.sidecarUnavailable = false
            self.writeIndicatorClearWork?.cancel()
            self.isWritingData = false
        }
        // Drain any buffer-copy dispatches that were already in flight on
        // writerQueue before isRecording was cleared.
        writerQueue.sync {}

        writerLock.lock()
        let writer = assetWriter
        let sidecar = pcmSidecar
        assetWriter = nil
        assetWriterInput = nil
        pcmSidecar = nil
        limiter = nil
        encoderConverter = nil
        encoderFormat = nil
        pendingTapBuffers.removeAll()
        writerLock.unlock()

        sidecar?.discard()
        writer?.cancelWriting()
        DispatchQueue.main.async {
            completion()
        }
    }

    private func appendBufferToWriter(_ buffer: AVAudioPCMBuffer) {
        writerLock.lock()

        guard let writer = assetWriter, let writerInput = assetWriterInput else {
            writerLock.unlock()
            return
        }

        // 1. Writer must be in .writing. A non-writing status (.failed,
        //    .cancelled, .completed) means appends will be rejected — tear
        //    down once and surface the real error rather than letting
        //    every subsequent tap callback re-trigger the same failure.
        guard writer.status == .writing else {
            let err = writer.error?.localizedDescription
                ?? "AVAssetWriter status \(writer.status.rawValue)"
            assetWriter = nil
            assetWriterInput = nil
            limiter = nil
            encoderConverter = nil
            encoderFormat = nil
            pendingTapBuffers.removeAll()
            let abortedSidecar = pcmSidecar
            pcmSidecar = nil
            consecutiveWriteErrors = 0
            writerLock.unlock()
            logger.error("AVAssetWriter not in .writing state — \(err, privacy: .public)")
            abortedSidecar?.close()
            writer.cancelWriting()
            DispatchQueue.main.async { self.lastError = err }
            return
        }

        // 2. Drain anything that arrived during a previous backpressure
        //    window. We process in arrival order so PTS stays monotonic and
        //    the limiter sees samples in capture order. If the writer flips
        //    back to "not ready" mid-drain, we leave the remainder queued
        //    and pick up on the next callback.
        var teardownRequested = false
        while !pendingTapBuffers.isEmpty {
            guard writerInput.isReadyForMoreMediaData else { break }
            let pending = pendingTapBuffers.removeFirst()
            let result = processAndAppend(pending, writerInput: writerInput)
            if result == .teardown {
                teardownRequested = true
                break
            }
            if result == .backpressure {
                // Append returned false but we're under threshold — put it
                // back at the front and stop draining; try again next call.
                pendingTapBuffers.insert(pending, at: 0)
                break
            }
        }

        if teardownRequested {
            // processAndAppend already cleared writer state and posted the
            // error. Drop any further pending audio — there's nowhere to
            // write it.
            pendingTapBuffers.removeAll()
            writerLock.unlock()
            return
        }

        // 3. Handle the new buffer. Fast path: queue empty and writer ready
        //    → append directly. Otherwise queue it so the next callback
        //    can drain in order.
        if pendingTapBuffers.isEmpty && writerInput.isReadyForMoreMediaData {
            switch processAndAppend(buffer, writerInput: writerInput) {
            case .ok:
                break
            case .backpressure:
                // Rare: writer flipped to "not ready" between the check and
                // the append. Queue it for next time.
                pendingTapBuffers.append(buffer)
            case .teardown:
                pendingTapBuffers.removeAll()
            }
        } else {
            // Backpressured — queue and drain later. Cap memory growth at
            // maxPendingTapBuffers; dropping the OLDEST preserves the
            // monotonic-PTS invariant and is the same failure mode the
            // legacy code had (a buffer lost), but only fires after ~2 s
            // of sustained backpressure rather than every 15 s.
            if pendingTapBuffers.count >= Self.maxPendingTapBuffers {
                pendingTapBuffers.removeFirst()
                logger.warning("Pending tap buffer queue overflowed — dropping oldest. Writer is wedged.")
            }
            pendingTapBuffers.append(buffer)
        }

        writerLock.unlock()
    }

    /// Outcome of attempting to send a single tap buffer through the writer.
    private enum AppendResult {
        /// Sample buffer successfully appended; `writerFrameCount` advanced.
        case ok
        /// `writerInput.append` returned false (or a pre-append step
        /// produced no usable sample buffer). Caller should requeue.
        case backpressure
        /// Writer was torn down inside `processAndAppend` (e.g. the
        /// consecutiveWriteErrors threshold was reached). All writer state
        /// has already been cleared and `lastError` posted.
        case teardown
    }

    /// Run a tap-format buffer through limiter → converter → sidecar →
    /// AVAssetWriterInput.append. Caller MUST hold writerLock and have
    /// already verified `writer.status == .writing` and
    /// `writerInput.isReadyForMoreMediaData == true`. PTS is stamped from
    /// the current `writerFrameCount`, which only advances on success — so
    /// queued buffers that drain later still produce a monotonic timeline.
    private func processAndAppend(
        _ buffer: AVAudioPCMBuffer,
        writerInput: AVAssetWriterInput
    ) -> AppendResult {
        // Limiter runs in place on the raw tap buffer (multi-channel at hw
        // rate) — limiter is created/destroyed under writerLock.
        limiter?.process(buffer: buffer)

        // Convert tap buffer → mono PCM at the AAC-friendly rate. The same
        // converter handles both downmix and resample so the sample buffer
        // we hand to the writer always matches the format it was
        // configured with.
        guard let converter = encoderConverter, let target = encoderFormat else {
            return .backpressure
        }
        let outCapacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate)
        ) + 32
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else {
            consecutiveWriteErrors += 1
            return .backpressure
        }
        var convError: NSError?
        let convStatus = converter.convert(to: convertedBuffer, error: &convError) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        guard convStatus != .error, convertedBuffer.frameLength > 0 else {
            consecutiveWriteErrors += 1
            if let e = convError {
                logger.error("AVAudioConverter failed: \(e.localizedDescription, privacy: .public)")
            }
            return .backpressure
        }

        // Mirror to the sidecar before building the CMSampleBuffer — this
        // way the recovery copy captures audio even if sample-buffer
        // construction or the writer append fails.
        if let mono = convertedBuffer.floatChannelData?[0] {
            pcmSidecar?.append(mono, frameCount: Int(convertedBuffer.frameLength))
        }

        guard let sampleBuffer = makeSampleBuffer(from: convertedBuffer, startFrame: writerFrameCount) else {
            consecutiveWriteErrors += 1
            return .backpressure
        }

        // Log the first five presentation timestamps. Since PTS is derived
        // from a monotonically increasing frame counter at the encoder
        // rate, any oddity (invalid CMTime, non-monotonic sequence) shows
        // up here on first inspection.
        if ptsLogCount < 5 {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            logger.info(
                "PTS[\(self.ptsLogCount, privacy: .public)] value=\(pts.value, privacy: .public) ts=\(pts.timescale, privacy: .public) valid=\(pts.flags.contains(.valid) ? 1 : 0, privacy: .public) frames=\(convertedBuffer.frameLength, privacy: .public)"
            )
            ptsLogCount += 1
        }

        if writerInput.append(sampleBuffer) {
            writerFrameCount += Int64(convertedBuffer.frameLength)
            consecutiveWriteErrors = 0
            // Bump the write-flow indicator. Goes on main; the indicator's
            // own work-item rate-limits the off transition.
            DispatchQueue.main.async { [weak self] in
                self?.markDataFlowing()
            }
            return .ok
        }

        // Append failed under the threshold — caller will requeue.
        consecutiveWriteErrors += 1
        if consecutiveWriteErrors < writeErrorThreshold {
            return .backpressure
        }

        // Hard failure: tear the writer down so we surface a real error
        // instead of looping on the same broken instance.
        let failedWriter = assetWriter
        let err = failedWriter?.error?.localizedDescription
            ?? "AVAssetWriter status \(failedWriter?.status.rawValue ?? -1)"
        assetWriter = nil
        assetWriterInput = nil
        limiter = nil
        encoderConverter = nil
        encoderFormat = nil
        // Keep the sidecar on disk — the partial .m4a is being cancelled,
        // so the sidecar is the only recoverable copy.
        let abortedSidecar = pcmSidecar
        pcmSidecar = nil
        consecutiveWriteErrors = 0

        abortedSidecar?.close()
        failedWriter?.cancelWriting()
        logger.error("AVAssetWriter append failed \(self.writeErrorThreshold, privacy: .public)x — \(err, privacy: .public)")
        DispatchQueue.main.async {
            self.lastError = err
        }
        return .teardown
    }

    private func makeSampleBuffer(from monoBuffer: AVAudioPCMBuffer, startFrame: Int64) -> CMSampleBuffer? {
        let frameCount = Int(monoBuffer.frameLength)
        guard frameCount > 0,
              let channelData = monoBuffer.floatChannelData?[0] else {
            return nil
        }
        let bytesPerFrame = MemoryLayout<Float>.size
        let dataSize = frameCount * bytesPerFrame
        let sampleRate = monoBuffer.format.sampleRate

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard fmtStatus == noErr, let formatDesc = formatDescription else { return nil }

        // CMBlockBuffer needs to own its bytes — the tap buffer's memory is reused after this callback.
        guard let dataPtr = malloc(dataSize) else { return nil }
        memcpy(dataPtr, channelData, dataSize)

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: dataPtr,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let block = blockBuffer else {
            free(dataPtr)
            return nil
        }

        let pts = CMTime(value: startFrame, timescale: CMTimeScale(sampleRate))
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: frameCount,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr else { return nil }
        return sampleBuffer
    }
    
    /// Finalize the in-progress recording.
    ///
    /// Completion delivers `.success(url)` for a saved file, `.success(nil)`
    /// when nothing was captured (silent discard — no error surfaced to the
    /// user), or `.failure(error)` for an actual failure during finalization.
    /// The zero-frame case is treated as a silent discard rather than an
    /// error because by spec the user should never see a failure screen for
    /// a session where the meter showed real signal — and if the meter saw
    /// nothing either, the take is simply empty and unworth surfacing.
    func stopRecording(completion: @escaping (Result<URL?, Error>) -> Void) {
        isRecording = false
        DispatchQueue.main.async {
            self.sidecarUnavailable = false
            self.writeIndicatorClearWork?.cancel()
            self.isWritingData = false
        }
        // Drain any buffer-copy dispatches that were already in flight on
        // writerQueue before isRecording was cleared.
        writerQueue.sync {}

        writerLock.lock()

        // Drain anything still queued from a backpressure window so the
        // tail of the recording isn't lost. With isRecording already
        // false and writerQueue.sync above, no new buffers will arrive
        // and pendingTapBuffers is in its final state. Bound the loop at
        // ~1 s of real time so a permanently-wedged writer can't hang
        // stopRecording — anything still queued past that is dropped.
        if let input = assetWriterInput, assetWriter != nil {
            var spinAttempts = 0
            let maxSpins = 100   // × 10 ms = 1 s
            while !pendingTapBuffers.isEmpty && spinAttempts < maxSpins {
                if !input.isReadyForMoreMediaData {
                    writerLock.unlock()
                    Thread.sleep(forTimeInterval: 0.010)
                    writerLock.lock()
                    spinAttempts += 1
                    continue
                }
                let pending = pendingTapBuffers.removeFirst()
                let result = processAndAppend(pending, writerInput: input)
                if result == .teardown {
                    // processAndAppend already cleared writer state.
                    break
                }
                if result == .backpressure {
                    pendingTapBuffers.insert(pending, at: 0)
                    writerLock.unlock()
                    Thread.sleep(forTimeInterval: 0.010)
                    writerLock.lock()
                    spinAttempts += 1
                }
            }
            if !pendingTapBuffers.isEmpty {
                logger.warning("stopRecording: writer stayed backpressured for >1 s — dropping \(self.pendingTapBuffers.count, privacy: .public) buffered frames.")
            }
        }

        let writer = assetWriter
        let input = assetWriterInput
        let sidecar = pcmSidecar
        let appendedFrameCount = writerFrameCount
        assetWriter = nil
        assetWriterInput = nil
        pcmSidecar = nil
        limiter = nil
        encoderConverter = nil
        encoderFormat = nil
        pendingTapBuffers.removeAll()
        writerLock.unlock()

        guard let writer = writer, let input = input else {
            // No writer, but a sidecar may still exist — keep it so a
            // recovery pass can surface it.
            sidecar?.close()
            DispatchQueue.main.async {
                completion(.failure(RecordingError.noActiveRecording))
            }
            return
        }

        // Zero-frame guard — silent discard, no error. The writer never got a
        // buffer (engine still warming up, or STOP fired inside the same
        // render cycle as RECORD). Drop the sidecar, cancel the writer, and
        // return `.success(nil)` so the VM treats it as "nothing to do" and
        // returns to .ready without an error screen.
        if appendedFrameCount == 0 {
            logger.info("stopRecording with zero frames appended — silently discarding")
            sidecar?.discard()
            writer.cancelWriting()
            DispatchQueue.main.async {
                completion(.success(nil))
            }
            return
        }

        input.markAsFinished()
        writer.finishWriting {
            DispatchQueue.main.async {
                if writer.status == .completed {
                    // Main file is intact — the sidecar is now redundant.
                    sidecar?.discard()
                    completion(.success(writer.outputURL))
                } else {
                    // Finalize failed — the sidecar is the only intact copy.
                    sidecar?.close()
                    let reason = writer.error?.localizedDescription ?? "status \(writer.status.rawValue)"
                    completion(.failure(RecordingError.writerFinishedWithError(reason)))
                }
            }
        }
    }
    
    func setDevice(_ device: AVCaptureDevice) {
        guard let id = audioDeviceID(forUID: device.uniqueID) else {
            logger.error("Failed to translate device UID to AudioDeviceID: \(device.uniqueID, privacy: .public)")
            return
        }

        // Pre-check: does this device actually have input streams?
        //
        // AUHAL silently falls back to a previously-bound device when asked
        // to bind to one with no input streams (output-only devices,
        // aggregate devices whose sub-devices have no input, broken
        // virtuals). The engine "succeeds" but feeds audio from the wrong
        // source — the meter shows signal that doesn't match the user's
        // pick. Reject the switch here before AUHAL gets a chance.
        //
        // Note: this is a NECESSARY but not SUFFICIENT check. Some virtual
        // devices (Zoom, Descript loopback) honestly report input streams
        // but CoreAudio still refuses them as the system default — the
        // post-rebuild systemDefault re-read in rebuildEngine catches
        // those.
        if !deviceHasInputStreams(id) {
            logger.info("Selected device has no input streams — refusing switch: \(device.localizedName, privacy: .public)")
            DispatchQueue.main.async { self.selectedDeviceUsable = false }
            return
        }
        DispatchQueue.main.async { self.selectedDeviceUsable = true }

        // Change the macOS system default input device, then rebuild the
        // engine with `deviceID: nil` so AVAudioEngine binds the inputNode
        // via the system-default path.
        //
        // We deliberately avoid AVAudioEngine's setDeviceID route here.
        // setDeviceID races AUHAL's HW-stream-description commit on
        // freshly-arrived USB devices: the new inputNode reports a
        // plausible-looking outputFormat, but the underlying HW format
        // isn't yet what AUHAL has actually committed. AVAudioEngine.connect
        // then throws an NSException ("Input HW format and tap format not
        // matching") from AVAudioIONodeImpl::SetOutputFormat — uncatchable
        // from Swift do/try/catch, crashing without the ExceptionCatcher
        // wrapper. Even running the engine briefly to force commit, with
        // multiple retries, doesn't reliably win the race on all devices.
        //
        // The default-device path bypasses the issue entirely because
        // AVAudioEngine binds the inputNode through AUHAL's default-device
        // resolution at engine construction time, which doesn't race the
        // same way. The "Try Again" recovery in the UI proves this: it
        // calls audioEngine.start() which goes down this same rebuild-with-
        // nil path and reliably succeeds.
        //
        // Side effect: the macOS system default input changes. For
        // DoublEnder's single-purpose use case (a podcast guest recording
        // their side of a remote interview) this is acceptable — the user
        // explicitly picked this mic and any other audio app honoring the
        // system default will follow that choice too.
        if setSystemDefaultInputDevice(id) {
            // intendedDeviceID lets rebuildEngine's post-rebuild verification
            // detect AUHAL silently falling back to a different device when
            // the requested one has no usable input streams.
            rebuildEngine(with: nil, intendedDeviceID: id)
        } else {
            // Fall back to the setDeviceID path with ExceptionCatcher
            // protection. May still surface a format error on a freshly-
            // arrived USB device, but at least it won't crash.
            logger.warning("Could not set system default input — falling back to setDeviceID for \(device.uniqueID, privacy: .public)")
            rebuildEngine(with: id)
        }
    }

    /// Read the current macOS system-wide default input device via
    /// CoreAudio. Used by `rebuildEngine` to detect silent fallback:
    /// `setSystemDefaultInputDevice` returns noErr for some virtual devices
    /// (ZoomAudioDevice, Descript Loopback Recorder, others) but CoreAudio
    /// quietly refuses the change and leaves the property at its previous
    /// value. Re-reading after the rebuild tells us what the engine is
    /// actually on. Returns nil on query failure.
    private func currentSystemDefaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return (status == noErr && deviceID != 0) ? deviceID : nil
    }

    /// Set the macOS system-wide default input device via CoreAudio.
    /// Returns true on success. The change is synchronous — once this
    /// returns, a freshly-constructed AVAudioEngine will see the new device
    /// as its inputNode's bound device.
    ///
    /// Caveat: returning true does NOT guarantee CoreAudio actually applied
    /// the change. Some virtual devices accept the call (no error) but
    /// CoreAudio silently leaves the system default at its previous value.
    /// Callers must re-read via `currentSystemDefaultInputDevice` to verify.
    private func setSystemDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )
        if status != noErr {
            logger.error(
                "Set system default input failed: status \(status, privacy: .public)"
            )
            return false
        }
        return true
    }

    /// Resolve an `AVCaptureDevice.uniqueID` to its CoreAudio device ID.
    private func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID: CFString = uid as CFString
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &cfUID) { ptr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                ptr,
                &size,
                &deviceID
            )
        }
        return status == noErr ? deviceID : nil
    }

    /// True when the CoreAudio device has at least one input stream.
    /// Output-only devices, aggregate devices with no input sub-devices,
    /// and broken virtuals return false. Returns true on query failure to
    /// avoid false rejections — better to let AUHAL try and surface its
    /// own error than to block a device because we couldn't enumerate.
    private func deviceHasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr else {
            logger.warning("Could not query input streams for device \(deviceID, privacy: .public): status \(status, privacy: .public) — assuming usable")
            return true
        }
        let streamCount = Int(dataSize) / MemoryLayout<AudioStreamID>.size
        return streamCount > 0
    }

    /// Sum of `mNumberChannels` across every buffer in the device's input
    /// stream-configuration AudioBufferList. This is the *real* input
    /// channel count — aggregate devices sometimes report nonzero
    /// `kAudioDevicePropertyStreams` even when no member device contributes
    /// channels, but this property reflects the actual buffer layout AUHAL
    /// will use. Returns -1 on query failure (distinct from 0 so the log
    /// can disambiguate "query failed" from "really zero channels").
    /// Diagnostic-only at the moment — not consulted for the
    /// `selectedDeviceUsable` decision.
    private func deviceInputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else {
            logger.warning("[DIAG deviceInputChannelCount] dataSize query failed device=\(deviceID, privacy: .public) status=\(sizeStatus, privacy: .public)")
            return -1
        }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buf.deallocate() }
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, buf)
        guard status == noErr else {
            logger.warning("[DIAG deviceInputChannelCount] get failed device=\(deviceID, privacy: .public) status=\(status, privacy: .public)")
            return -1
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
        var total = 0
        for buffer in bufferList {
            total += Int(buffer.mNumberChannels)
        }
        return total
    }

    private func transportType(for deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        return status == noErr ? transport : nil
    }

    /// Only an explicit Aggregate or Virtual transport demotes a device —
    /// anything else (incl. Unknown) stays a microphone so real hardware is
    /// never hidden in the de-emphasized section.
    private func classify(_ device: AVCaptureDevice) -> InputDeviceKind {
        guard let id = audioDeviceID(forUID: device.uniqueID),
              let transport = transportType(for: id) else {
            return .microphone
        }
        switch transport {
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual:
            return .virtual
        default:
            return .microphone
        }
    }
}

private final class LookaheadLimiter {
    private let threshold: Float = 0.891  // -1.0 dBFS
    private let lookaheadSamples: Int
    private let attackStep: Float
    private let releaseCoeff: Float

    private var delayBuffers: [[Float]]
    private var writeIndices: [Int]
    private var currentGains: [Float]

    // Per-channel monotone deques for O(n) sliding window max.
    // Each deque stores (absolute-value, circular-buffer index) pairs in
    // decreasing order of value so the front is always the current window max.
    private var maxDeques: [[(value: Float, idx: Int)]]

    init(sampleRate: Double, channels: Int) {
        let lookaheadMs: Double = 5.0
        let releaseMs: Double = 80.0
        let ch = max(channels, 1)

        self.lookaheadSamples = max(1, Int(lookaheadMs * 0.001 * sampleRate))
        self.attackStep = 1.0 / Float(self.lookaheadSamples)
        self.releaseCoeff = Float(1.0 - exp(-1.0 / (releaseMs * 0.001 * sampleRate)))
        self.delayBuffers = Array(repeating: Array(repeating: 0, count: self.lookaheadSamples), count: ch)
        self.writeIndices = Array(repeating: 0, count: ch)
        self.currentGains = Array(repeating: 1.0, count: ch)
        self.maxDeques = Array(repeating: [], count: ch)
    }

    func process(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = min(Int(buffer.format.channelCount), delayBuffers.count)
        let L = lookaheadSamples

        for c in 0..<channelCount {
            var delay = delayBuffers[c]
            var writeIdx = writeIndices[c]
            var currentGain = currentGains[c]
            var deque = maxDeques[c]
            let data = channelData[c]

            for i in 0..<frameCount {
                let inSample = data[i]
                let inAbs = abs(inSample)

                // The slot about to be overwritten is leaving the window —
                // evict it from the front of the deque if it's there.
                let evictIdx = writeIdx
                if deque.first?.idx == evictIdx { deque.removeFirst() }

                // Emit the oldest delayed sample before overwriting the slot.
                let delayedSample = delay[writeIdx]
                delay[writeIdx] = inSample
                writeIdx = (writeIdx + 1) % L

                // Maintain decreasing-value invariant: drop any back entries
                // smaller than the incoming value — they can never be the max
                // while the new entry is still in the window.
                while let last = deque.last, last.value <= inAbs { deque.removeLast() }
                deque.append((value: inAbs, idx: evictIdx))

                // Front of deque is always the window max — O(1) lookup.
                let peak = deque.first?.value ?? 0
                let targetGain: Float = peak > threshold ? threshold / peak : 1.0

                if targetGain < currentGain {
                    currentGain = max(targetGain, currentGain - attackStep)
                } else if targetGain > currentGain {
                    currentGain += (targetGain - currentGain) * releaseCoeff
                }

                var out = delayedSample * currentGain
                if out > threshold { out = threshold }
                else if out < -threshold { out = -threshold }
                data[i] = out
            }

            delayBuffers[c] = delay
            writeIndices[c] = writeIdx
            currentGains[c] = currentGain
            maxDeques[c] = deque
        }
    }
}
