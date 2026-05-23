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
    /// The writer was opened and immediately closed with no buffers ever
    /// appended. Typically happens when the user taps RECORD then STOP
    /// faster than the engine takes to deliver its first buffer on a
    /// freshly-built graph (first launch, or post device hot-swap).
    /// startRecording briefly blocks on the first tap delivery to make
    /// this rare; this case is the safety net for the residue.
    case noAudioCaptured

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
        case .noAudioCaptured:
            return "No audio was captured — the recording was too brief. Try again."
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

    // Serial queue for all AVAssetWriter / PCMSidecar work. Moving this
    // off the AVAudioEngine tap thread eliminates NSLock, malloc, and file
    // I/O from the real-time audio callback.
    private let writerQueue = DispatchQueue(
        label: "io.github.sevmorris.DoublEnder.writer",
        qos: .userInitiated
    )

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
    
    private func rebuildEngine(with deviceID: AudioDeviceID? = nil) {
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
            // AUHAL's CoreAudio-side device binding updates synchronously,
            // but AVAudioEngine's cached view of outputFormat(forBus:) does
            // NOT refresh until the inputNode is actually pulled. Installing
            // a no-op tap forces that refresh: AUHAL queries the newly-set
            // device for its real format and propagates it to the engine.
            //
            // Without this, the first launch path (setDeviceID called) reads
            // a stale format, uses it to wire up the chain, and engine.start
            // later fails with kAudioUnitErr_FailedInitialization (-10875)
            // because the dynamics processor's bus format disagrees with
            // what's actually being pushed in.
            newEngine.inputNode.installTap(onBus: 0, bufferSize: 256, format: nil) { _, _ in }
            newEngine.inputNode.removeTap(onBus: 0)
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
            DispatchQueue.main.async { self.lastError = message }
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

        // One canonical Float32 deinterleaved format used for every
        // connection in the chain AND for the tap. Apple's audio-unit
        // effects (incl. the dynamics processor) require Float32
        // deinterleaved on their buses; using a single explicit format
        // eliminates any chance of a mismatch between connect() and the
        // node's actual stream description.
        guard let chainFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate:   nativeFormat.sampleRate,
            channels:     nativeFormat.channelCount,
            interleaved:  false
        ) else {
            let message = "Could not create canonical chain format for selected input."
            DispatchQueue.main.async { self.lastError = message }
            return
        }

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
        newEngine.connect(inputNode, to: dynamics, format: chainFormat)

        // Engine-scoped no-op sink. The render block has to be present but
        // can immediately return noErr — the audio it would otherwise consume
        // is already being captured by the tap installed on `dynamics` below.
        let sink = AVAudioSinkNode { _, _, _ in noErr }
        newEngine.attach(sink)
        newEngine.connect(dynamics, to: sink, format: chainFormat)

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

        newEngine.prepare()
        do {
            try newEngine.start()
            self.audioEngine = newEngine
            engineConfigObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: newEngine,
                queue: .main
            ) { [weak self] _ in self?.handleEngineConfigurationChange() }
        } catch {
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
            DispatchQueue.main.async { self.lastError = message }
        }
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
        self.availableInputDevices = session.devices
        deviceKindCache = Dictionary(
            uniqueKeysWithValues: session.devices.map { ($0.uniqueID, classify($0)) }
        )

        // Diff against the previous device list to detect hot-plug arrivals.
        // The first pass after init seeds the known-set without firing any
        // callbacks — launch-time device population is not a "new arrival"
        // from the user's perspective and is handled by the VM's USB-on-
        // launch policy separately. Subsequent refreshes (from the CoreAudio
        // listener, app activation, system wake, or engine config change)
        // fire onNewUSBDeviceDetected for any USB UID that wasn't there before.
        let currentUIDs = Set(session.devices.map { $0.uniqueID })
        if hasSeededKnownDevices {
            let newUIDs = currentUIDs.subtracting(knownInputDeviceUIDs)
            for uid in newUIDs {
                if let device = session.devices.first(where: { $0.uniqueID == uid }),
                   isUSBDevice(device) {
                    onNewUSBDeviceDetected?(device)
                }
            }
        } else {
            hasSeededKnownDevices = true
        }
        knownInputDeviceUIDs = currentUIDs

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
        writerLock.unlock()

        isRecording = true
    }

    /// Abort the in-progress recording without finalizing. `cancelWriting()`
    /// deletes the partial output file. Used by the "Quit Without Saving"
    /// confirmation path.
    func cancelRecording(completion: @escaping () -> Void) {
        isRecording = false
        DispatchQueue.main.async { self.sidecarUnavailable = false }
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

        // Transient encoder backpressure is normal — dropping a single
        // buffer here is the documented contract for AVAssetWriterInput.
        guard writerInput.isReadyForMoreMediaData else {
            writerLock.unlock()
            return
        }

        // Limiter runs in place on the raw tap buffer (multi-channel at hw
        // rate) — limiter is created/destroyed under writerLock.
        limiter?.process(buffer: buffer)

        // 2. Convert tap buffer → mono PCM at the AAC-friendly rate. The
        //    same converter handles both downmix and resample so the
        //    sample buffer we hand to the writer always matches the format
        //    it was configured with.
        guard let converter = encoderConverter, let target = encoderFormat else {
            writerLock.unlock()
            return
        }
        let outCapacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate)
        ) + 32
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else {
            consecutiveWriteErrors += 1
            writerLock.unlock()
            return
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
            writerLock.unlock()
            return
        }

        // Mirror to the sidecar before building the CMSampleBuffer — this
        // way the recovery copy captures audio even if sample-buffer
        // construction or the writer append fails.
        if let mono = convertedBuffer.floatChannelData?[0] {
            pcmSidecar?.append(mono, frameCount: Int(convertedBuffer.frameLength))
        }

        guard let sampleBuffer = makeSampleBuffer(from: convertedBuffer, startFrame: writerFrameCount) else {
            consecutiveWriteErrors += 1
            writerLock.unlock()
            return
        }

        // 3. Log the first five presentation timestamps. Since PTS is
        //    derived from a monotonically increasing frame counter at the
        //    encoder rate, any oddity (invalid CMTime, non-monotonic
        //    sequence) shows up here on first inspection.
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
            writerLock.unlock()
        } else {
            consecutiveWriteErrors += 1
            if consecutiveWriteErrors >= writeErrorThreshold {
                // Capture and clear writer state so no further appends occur.
                let failedWriter = assetWriter
                // 4. Surface the writer's actual localized error verbatim.
                //    Use the already-captured local rather than re-reading the
                //    property, which will be nilled on the very next line.
                let err = failedWriter?.error?.localizedDescription
                    ?? "AVAssetWriter status \(failedWriter?.status.rawValue ?? -1)"
                assetWriter = nil
                assetWriterInput = nil
                limiter = nil
                encoderConverter = nil
                encoderFormat = nil
                // Keep the sidecar on disk — the partial .m4a is being
                // cancelled, so the sidecar is the only recoverable copy.
                let abortedSidecar = pcmSidecar
                pcmSidecar = nil
                consecutiveWriteErrors = 0
                writerLock.unlock()

                abortedSidecar?.close()
                // Cancel the partial file — it can't be finalized in this state.
                failedWriter?.cancelWriting()
                logger.error("AVAssetWriter append failed \(self.writeErrorThreshold, privacy: .public)x — \(err, privacy: .public)")
                DispatchQueue.main.async {
                    self.lastError = err
                }
            } else {
                writerLock.unlock()
            }
        }
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
    
    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        isRecording = false
        DispatchQueue.main.async { self.sidecarUnavailable = false }
        // Drain any buffer-copy dispatches that were already in flight on
        // writerQueue before isRecording was cleared.
        writerQueue.sync {}

        writerLock.lock()
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

        // Zero-frame guard. If the tap never delivered a buffer to the
        // writer (either because the engine was still warming up — see the
        // first-buffer wait in startRecording — or because STOP fired
        // inside the same render cycle as RECORD), finishWriting() would
        // happily produce a 0-byte file and the caller's size>0 check
        // would blame the mic. Cancel the writer, drop the sidecar, and
        // surface a specific error so the caller can show a useful
        // "recording too brief" message.
        if appendedFrameCount == 0 {
            logger.warning("stopRecording with zero frames appended — cancelling writer (no audio captured)")
            sidecar?.discard()
            writer.cancelWriting()
            DispatchQueue.main.async {
                completion(.failure(RecordingError.noAudioCaptured))
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
        if let id = audioDeviceID(forUID: device.uniqueID) {
            rebuildEngine(with: id)
        } else {
            logger.error("Failed to translate device UID to AudioDeviceID: \(device.uniqueID, privacy: .public)")
        }
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
