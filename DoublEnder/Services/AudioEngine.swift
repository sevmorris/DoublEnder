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
    /// Current input level in dBFS (`LevelMeter.dbFloor`…0). Peak-hold,
    /// smoothed on writerQueue and published to the UI. Display-only — never
    /// affects recording.
    @Published var meterLevel: Float = LevelMeter.dbFloor
    /// Latches true when input peaks reach full scale; auto-clears after
    /// `LevelMeter.clipIndicatorHoldDuration`. Display-only.
    @Published var isClipping: Bool = false
    /// True when the PCM sidecar could not be opened for this recording —
    /// crash recovery is unavailable for the current take. (M4)
    @Published var sidecarUnavailable: Bool = false
    /// True when the active input is delivering a sample rate ≤ 16 kHz,
    /// which typically indicates Bluetooth SCO (8 kHz narrowband) or another
    /// low-quality path. Does not stop recording — surfaces a UI warning. (M5)
    @Published var lowQualityInput: Bool = false

    /// True when the most recent `rebuildSession` call reached a running
    /// AVCaptureSession successfully. The RecorderViewModel derives the
    /// on-screen device label from this — when true, the label shows the
    /// localized name of `selectedInputDeviceID`; when false, it shows
    /// "(no input)" because the session couldn't bind / the device input
    /// couldn't be constructed / startRunning threw.
    ///
    /// Starts `true` so the initial UI (before requestPermissions has
    /// driven the first rebuild) doesn't flash "(no input)". The first
    /// rebuild flips it accordingly.
    @Published var engineHealthy: Bool = true

    /// False when `setDevice` rejected the most recent user pick because
    /// the CoreAudio device has no input streams (output-only device,
    /// disabled aggregate sub-device, etc.). We don't change the system
    /// default and don't rebuild — the previously-bound device stays
    /// active — but the UI label reads "(no input)" so the user knows
    /// their pick can't actually record. `engineHealthy` remains true
    /// because the engine itself is fine; the issue is the user's choice.
    @Published var selectedDeviceUsable: Bool = true

    /// True while `rebuildSession` is executing. The RecorderViewModel
    /// gates RECORD on `!isRebuilding` so a tap during this transient
    /// window can't race a half-built session. Set true at the top of
    /// rebuildSession; set false on every exit path so it accurately
    /// tracks "is the capture session in flux right now."
    @Published var isRebuilding: Bool = false
    /// True when buffers are actively being appended to the writer (within
    /// the last ~150 ms). Drives the on-screen write-flow indicator dot.
    /// Distinct from `isRecording` (record-button state) — this only goes
    /// true when AVAssetWriterInput.append actually returns true.
    @Published var isWritingData: Bool = false
    /// True while AVCaptureSession is interrupted mid-recording — another
    /// app has grabbed the audio hardware. The interruption watchdog will
    /// fail the take if the session doesn't recover within 5 s. Published
    /// so the VM can surface a non-modal warning without stopping the clock.
    @Published var sessionInterrupted: Bool = false
    /// True after the first dropped frame this take — `isReadyForMoreMediaData`
    /// returned false and at least one buffer was discarded. Cleared on
    /// recording start and on stop. Published for the VM warning display.
    @Published var droppedFrameWarning: Bool = false

    private let aacBitRate: Int = 256_000

    // ── AVCaptureSession capture front end ───────────────────────────────
    // CMSampleBuffers flow straight from AVCaptureAudioDataOutput's delegate
    // into AVAssetWriterInput.append — the same signal path QuickTime uses.
    // No AVAudioEngine, no tap, no AU graph, no per-buffer PCM conversion.
    private var captureSession: AVCaptureSession?
    private var currentInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var isRecording = false

    // ── Writer state ─────────────────────────────────────────────────────
    // The AVAssetWriter is built upfront in startRecording. The
    // AVAssetWriterInput is built on the FIRST CMSampleBuffer arrival in the
    // delegate, using that sample's CMFormatDescription as the
    // `sourceFormatHint`. The hint tells the writer the exact shape of PCM
    // to expect (sample rate, channel count, interleaving, bit depth) and
    // lets it configure any internal transcoding it needs without us doing
    // format guesswork. The first sample's PTS becomes the session's start
    // time, so timestamps are exact CoreMedia values rather than synthesised
    // from a frame counter.
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var pcmSidecar: PCMSidecar?
    /// Output settings (AAC or WAV) chosen at startRecording and consumed
    /// by the delegate when it builds the writer input on first sample.
    /// Cleared on stop / cancel.
    private var pendingOutputSettings: [String: Any]?
    /// Destination URL for the take. Held so the delegate can pass it to
    /// PCMSidecar.init once the source format description is known.
    private var pendingFileURL: URL?
    private let writerLock = NSLock()
    /// uniqueID → kind, rebuilt on each device refresh so the picker
    /// doesn't re-query CoreAudio on every SwiftUI render.
    private var deviceKindCache: [String: InputDeviceKind] = [:]
    private var consecutiveWriteErrors = 0
    // 3 consecutive drops ≈ 30 ms of silence before failing the take.
    // Lowered from 5 (≈50 ms) — 30 ms is already audible on a word boundary;
    // failing sooner triggers the sidecar recovery path before more audio is lost.
    private let writeErrorThreshold = 3
    /// Consecutive sample buffers dropped because the writer wasn't ready.
    /// Sustained backpressure means audio is being lost — treat like a
    /// write failure once the threshold is hit.
    private var consecutiveDropCount = 0
    /// True once a dropped-frame warning has been published for the current
    /// take. Prevents re-publishing the same warning on every subsequent drop
    /// in the same run. Protected by writerLock; reset in startRecording.
    private var hasWarnedDroppedFrame = false
    /// True once the delegate has appended at least one sample buffer to
    /// the writer in the current take. stopRecording uses this to
    /// distinguish "writer never started a session" (silent discard,
    /// .success(nil)) from "writer wrote something" (finalize as usual).
    private var didAppendAtLeastOneSample = false
    /// UID of the input device bound when the current take started. Used to
    /// detect unplug mid-recording when refreshDevices runs.
    private var recordingInputDeviceUID: String?
    /// Prevents firing onDisconnectedDuringRecording more than once per take.
    private var disconnectStopPending = false
    /// Prevents duplicate idle input-loss callbacks while CoreAudio churns
    /// through several device-list updates for a single physical unplug.
    private var idleInputLossNotified = false

    // Serial queue for all AVAssetWriter / PCMSidecar work. Set as the
    // delegate queue on AVCaptureAudioDataOutput, so every CMSampleBuffer
    // arrives here in serial order — no extra dispatch needed between the
    // delegate, the writer append, and the sidecar mirror.
    private let writerQueue = DispatchQueue(
        label: "io.github.sevmorris.DoublEnder.writer",
        qos: .userInitiated
    )
    /// Exponential smoother for the live peak-hold meter; read/written only on writerQueue.
    private var smoothedPeakLevel: Float = LevelMeter.dbFloor
    /// Scheduled task that clears `isClipping` after the hold duration.
    private var clipClearWork: DispatchWorkItem?
    /// Scheduled "clear write indicator" task; cancelled and re-scheduled on
    /// every successful writer append so isWritingData only flips to false
    /// when buffers stop arriving for 150 ms.
    private var writeIndicatorClearWork: DispatchWorkItem?
    /// Watchdog fired when `AVCaptureSessionWasInterrupted` is not resolved
    /// within 5 s by either `InterruptionEnded` or an incoming sample buffer.
    /// Cancellation points: `captureSessionInterruptionEnded`, first successful
    /// sample in `markDataFlowing`, and all recording-stop/cancel paths.
    private var interruptionWatchdog: DispatchWorkItem?

    /// Called on the main thread when a device disconnects mid-recording.
    /// The string is a user-facing reason (device name + "disconnected").
    /// RecorderViewModel runs stop / save / fallback from this callback.
    var onDisconnectedDuringRecording: ((String) -> Void)?

    /// Called on the main thread when the bound input vanishes while idle.
    var onActiveInputLostWhileIdle: (() -> Void)?

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

    // MARK: - Capture session lifecycle

    func start() {
        if captureSession?.isRunning == true { return }
        rebuildSession(with: nil)
    }

    /// Build (or rebuild) the AVCaptureSession for audio-only capture and
    /// start it running. Mirrors the public-facing semantics of the old
    /// `rebuildEngine`: marks `isRebuilding` true, publishes errors via
    /// `lastError`, sets `engineHealthy` based on whether the session
    /// reached `.startRunning()` without throwing.
    ///
    /// `device` nil → use the system default input device (which is what
    /// AVCaptureDevice.default(for: .audio) returns).
    ///
    /// Caller is responsible for `setSystemDefaultInputDevice` if it wants
    /// to redirect the system default before invoking this. We re-read the
    /// system default after the session is running so silent CoreAudio
    /// rejections (some virtual devices) still surface as `selectedDeviceUsable`
    /// false.
    private func rebuildSession(
        with device: AVCaptureDevice? = nil,
        intendedDeviceID: AudioDeviceID? = nil
    ) {
        guard !isRecording else {
            logger.info("Refusing capture session rebuild during active recording")
            return
        }
        DispatchQueue.main.async { self.isRebuilding = true }

        // Tear down the prior session before building the new one. setSampleBufferDelegate(nil, ...)
        // first so any in-flight delegate callbacks complete before we drop refs.
        if let prior = captureSession {
            removeSessionObservers(for: prior)
            prior.stopRunning()
            if let out = audioOutput {
                out.setSampleBufferDelegate(nil, queue: nil)
            }
        }
        captureSession = nil
        currentInput = nil
        audioOutput = nil
        writerQueue.sync { self.smoothedPeakLevel = LevelMeter.dbFloor }
        DispatchQueue.main.async {
            self.clipClearWork?.cancel()
            self.clipClearWork = nil
            self.meterLevel = LevelMeter.dbFloor
            self.isClipping = false
        }

        let target: AVCaptureDevice
        if let device = device {
            target = device
        } else if let def = AVCaptureDevice.default(for: .audio) {
            target = def
        } else {
            let message = "No audio input device available."
            DispatchQueue.main.async {
                self.lastError = message
                self.engineHealthy = false
                self.isRebuilding = false
            }
            return
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: target)
        } catch {
            logger.error("AVCaptureDeviceInput init failed: \(error.localizedDescription, privacy: .public)")
            let message = "Could not bind to the selected input: \(error.localizedDescription)"
            DispatchQueue.main.async {
                self.lastError = message
                self.engineHealthy = false
                self.isRebuilding = false
            }
            return
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            let message = "Selected input device could not be added to the session."
            DispatchQueue.main.async {
                self.lastError = message
                self.engineHealthy = false
                self.isRebuilding = false
            }
            return
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        // No audioSettings — capture output delivers buffers in the device's
        // native format. The writer accepts whatever the device produces via
        // sourceFormatHint at writer-input creation time (see captureOutput
        // delegate); no per-buffer PCM conversion happens anywhere in the
        // path. Format forcing here was the source of click artifacts in
        // every prior attempt to set audioSettings, regardless of whether
        // interleaved or non-interleaved was specified — the writer's
        // internal transcoder handles any container/codec conversion needed
        // more reliably than a capture-stage conversion ever did.
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            let message = "Could not add audio output to the session."
            DispatchQueue.main.async {
                self.lastError = message
                self.engineHealthy = false
                self.isRebuilding = false
            }
            return
        }
        session.addOutput(output)
        // Delegate runs on writerQueue — the same serial queue stopRecording
        // uses with .sync to drain in-flight callbacks. The writerLock
        // mediates shared state with main-thread callers of startRecording /
        // stopRecording / cancelRecording.
        output.setSampleBufferDelegate(self, queue: writerQueue)

        session.commitConfiguration()
        session.startRunning()
        installSessionObservers(for: session)

        self.captureSession = session
        self.currentInput = input
        self.audioOutput = output

        // Surface the low-quality-input warning from the device's activeFormat
        // (best guess — the actual CMSampleBuffer rate could differ, but in
        // practice activeFormat reflects what AVCaptureSession will deliver).
        let nativeASBD = CMAudioFormatDescriptionGetStreamBasicDescription(
            target.activeFormat.formatDescription
        )?.pointee
        let nativeSampleRate = nativeASBD?.mSampleRate ?? 48_000
        let isLowQuality = nativeSampleRate <= 16_000
        DispatchQueue.main.async { self.lowQualityInput = isLowQuality }

        // Verify the session is on the intended device. Some virtual
        // devices accept setSystemDefaultInputDevice with noErr but
        // CoreAudio silently keeps the previous default; AVCaptureDevice
        // honors the user pick verbatim, so the more reliable check here is
        // simply comparing input.device.uniqueID to the intent. If the
        // caller passed `intendedDeviceID` (the CoreAudio AudioDeviceID),
        // resolve it back to an AVCaptureDevice and compare.
        let silentFallback: Bool
        if let intended = intendedDeviceID,
           let intendedDevice = audioCaptureDevice(forCoreAudioID: intended) {
            silentFallback = input.device.uniqueID != intendedDevice.uniqueID
            if silentFallback {
                logger.warning(
                    "Capture session bound to \(input.device.uniqueID, privacy: .public) but caller wanted \(intendedDevice.uniqueID, privacy: .public)"
                )
            }
        } else {
            silentFallback = false
        }

        DispatchQueue.main.async {
            self.engineHealthy = true
            self.isRebuilding = false
            if silentFallback {
                self.selectedDeviceUsable = false
            }
            self.idleInputLossNotified = false
        }
    }

    /// Resolve a CoreAudio AudioDeviceID back to an AVCaptureDevice. Used by
    /// rebuildSession to verify the user's intended pick was honored.
    private func audioCaptureDevice(forCoreAudioID id: AudioDeviceID) -> AVCaptureDevice? {
        var uid: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &uid)
        guard status == noErr, let cf = uid?.takeRetainedValue() else { return nil }
        let uidString = cf as String
        return availableInputDevices.first { $0.uniqueID == uidString }
    }


    /// Called on every successful AVAssetWriterInput.append. Bumps
    /// isWritingData true (if needed) and reschedules the "clear after
    /// 150 ms" task so the indicator stays lit while buffers keep arriving
    /// and goes dark only when the flow actually stops.
    ///
    /// Also cancels the interruption watchdog — a successfully appended
    /// sample proves the session recovered, regardless of whether
    /// `AVCaptureSessionInterruptionEnded` fired. Doing this here avoids
    /// scheduling a dedicated main-thread dispatch on every buffer.
    private func markDataFlowing() {
        if interruptionWatchdog != nil {
            interruptionWatchdog?.cancel()
            interruptionWatchdog = nil
            sessionInterrupted = false
        }
        if !isWritingData { isWritingData = true }
        writeIndicatorClearWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.isWritingData = false
        }
        writeIndicatorClearWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: item)
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

        notifyIfRecordingInputDisconnected()
        notifyIfActiveInputLostWhileIdle()
    }

    /// Poll the bound capture device while recording — CoreAudio device-list
    /// updates can lag behind a physical unplug, but `isConnected` flips promptly.
    func checkRecordingInputHealth() {
        guard isRecording, !disconnectStopPending else { return }
        guard let device = currentInput?.device else {
            triggerRecordingInputDisconnect(reason: "The selected microphone is no longer available")
            return
        }
        let activeUID = recordingInputDeviceUID ?? device.uniqueID
        let name = device.localizedName
        if !device.isConnected {
            triggerRecordingInputDisconnect(reason: "\(name) was disconnected")
            return
        }
        if !availableInputDevices.contains(where: { $0.uniqueID == activeUID && $0.isConnected }) {
            triggerRecordingInputDisconnect(reason: "\(name) was disconnected")
        }
    }

    /// If the active take's input device vanished from the system device
    /// list, ask RecorderViewModel to stop and finalize. Called from
    /// refreshDevices (CoreAudio listener, app activation, wake).
    private func notifyIfRecordingInputDisconnected() {
        guard isRecording, !disconnectStopPending else { return }
        guard let activeUID = recordingInputDeviceUID ?? currentInput?.device.uniqueID else {
            return
        }
        let bound = currentInput?.device
        let name = bound?.localizedName
            ?? availableInputDevices.first(where: { $0.uniqueID == activeUID })?.localizedName
            ?? "The selected microphone"
        let listedAndConnected = availableInputDevices.contains(where: {
            $0.uniqueID == activeUID && $0.isConnected
        })
        let hardwareConnected = bound?.isConnected ?? false
        guard !listedAndConnected || (bound?.uniqueID == activeUID && !hardwareConnected) else {
            return
        }
        triggerRecordingInputDisconnect(reason: "\(name) was disconnected")
    }

    private func triggerRecordingInputDisconnect(reason: String) {
        guard isRecording, !disconnectStopPending else { return }
        disconnectStopPending = true
        logger.warning("Recording input disconnected: \(reason, privacy: .public)")
        handleRecordingCaptureFailure(reason: reason)
    }

    /// When idle, rebuild if the bound input is gone so the user isn't left
    /// on a ghost device that can't actually capture.
    private func notifyIfActiveInputLostWhileIdle() {
        guard !isRecording else { return }
        guard let bound = currentInput?.device else { return }
        let uid = bound.uniqueID
        let stillUsable = bound.isConnected
            && availableInputDevices.contains(where: { $0.uniqueID == uid && $0.isConnected })
        if stillUsable {
            idleInputLossNotified = false
            return
        }
        guard !idleInputLossNotified else { return }
        idleInputLossNotified = true
        logger.warning("Active input lost while idle: \(bound.localizedName, privacy: .public)")
        DispatchQueue.main.async { self.onActiveInputLostWhileIdle?() }
    }

    /// Unified path for disconnect, runtime error, and unrecoverable interruption
    /// during an active take — delegates stop/finalize to RecorderViewModel.
    private func handleRecordingCaptureFailure(reason: String) {
        guard isRecording, disconnectStopPending else { return }
        logger.warning("Recording capture failure: \(reason, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.onDisconnectedDuringRecording?(reason)
        }
    }

    private func installSessionObservers(for session: AVCaptureSession) {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(captureSessionRuntimeError(_:)),
                           name: .AVCaptureSessionRuntimeError, object: session)
        center.addObserver(self, selector: #selector(captureSessionWasInterrupted(_:)),
                           name: .AVCaptureSessionWasInterrupted, object: session)
        center.addObserver(self, selector: #selector(captureSessionInterruptionEnded(_:)),
                           name: .AVCaptureSessionInterruptionEnded, object: session)
    }

    private func removeSessionObservers(for session: AVCaptureSession) {
        let center = NotificationCenter.default
        center.removeObserver(self, name: .AVCaptureSessionRuntimeError, object: session)
        center.removeObserver(self, name: .AVCaptureSessionWasInterrupted, object: session)
        center.removeObserver(self, name: .AVCaptureSessionInterruptionEnded, object: session)
    }

    @objc private func captureSessionRuntimeError(_ notification: Notification) {
        let err = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
        logger.error("AVCaptureSession runtime error: \(err?.localizedDescription ?? "unknown", privacy: .public)")
        guard isRecording, !disconnectStopPending else { return }
        disconnectStopPending = true
        handleRecordingCaptureFailure(reason: err?.localizedDescription ?? "runtime error")
    }

    @objc private func captureSessionWasInterrupted(_ notification: Notification) {
        logger.warning("AVCaptureSession interrupted")
        // Cancel any stale watchdog from a previous interruption, then arm a
        // new one. If neither InterruptionEnded nor an incoming sample buffer
        // clears the watchdog within 5 s, treat this as a hard device failure —
        // the session is permanently interrupted and the recording would be
        // silent. Brief interruptions (phone call overlay, Siri, etc.) recover
        // before the watchdog fires; only permanent losses trigger the teardown.
        interruptionWatchdog?.cancel()
        interruptionWatchdog = nil
        guard isRecording else { return }
        sessionInterrupted = true
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording, !self.disconnectStopPending else { return }
            logger.warning("Interruption watchdog fired — no recovery after 5 s")
            self.interruptionWatchdog = nil
            self.sessionInterrupted = false
            self.disconnectStopPending = true
            self.handleRecordingCaptureFailure(
                reason: "Recording stopped: microphone access was interrupted"
            )
        }
        interruptionWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: watchdog)
    }

    @objc private func captureSessionInterruptionEnded(_ notification: Notification) {
        // Disarm the watchdog before any other work — the interruption resolved.
        interruptionWatchdog?.cancel()
        interruptionWatchdog = nil
        sessionInterrupted = false
        guard isRecording else { return }
        if captureSession?.isRunning == false {
            captureSession?.startRunning()
        }
        if captureSession?.isRunning == false {
            guard !disconnectStopPending else { return }
            disconnectStopPending = true
            handleRecordingCaptureFailure(reason: "interruption ended but session did not restart")
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

    // MARK: - Recording lifecycle

    /// Begin a recording. The AVAssetWriter streams samples directly to
    /// `fileURL` — there is no temp file, no move step on stop. A raw-PCM
    /// crash-recovery sidecar is mirrored alongside it (see `PCMSidecar`).
    /// `format` selects the container/codec; `notes` is written as the
    /// file's description metadata tag.
    ///
    /// The AVAssetWriterInput is NOT created here. It's created in the
    /// captureOutput delegate the moment the first CMSampleBuffer arrives —
    /// that buffer's CMFormatDescription becomes the writer's
    /// `sourceFormatHint`, and its PTS becomes the session's start time.
    /// Deferring input creation eliminates all guessing about what format
    /// the capture session will deliver.
    func startRecording(to fileURL: URL, format: OutputFormat = .aac, notes: String = "") throws {
        guard captureSession?.isRunning == true else {
            throw RecordingError.engineNotRunning
        }

        DispatchQueue.main.async {
            self.clipClearWork?.cancel()
            self.clipClearWork = nil
            self.isClipping = false
            self.droppedFrameWarning = false
        }

        // AVAssetWriter refuses to start if the file already exists.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            logger.warning("Output file already exists — removing: \(fileURL.lastPathComponent, privacy: .public)")
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                throw RecordingError.writerFailedToStart(
                    "Could not remove existing file '\(fileURL.lastPathComponent)': \(error.localizedDescription)"
                )
            }
        }

        let fileType: AVFileType = (format == .aac) ? .m4a : .wav

        // outputSettings — fixed parameters for the encode/transcode. The
        // writer's internal transcoder handles any sample-rate or channel
        // conversion needed between the source (whatever the capture
        // device delivers) and these targets.
        //
        // AAC: mono at 48 kHz, 256 kbps — podcast-grade. Writer downmixes
        //   multi-channel input and resamples to 48 kHz internally.
        // WAV: mono int24 at 48 kHz — uncompressed podcast-delivery standard.
        //   Writer downmixes / resamples and packs Float32 input to int24.
        let outputSettings: [String: Any]
        switch format {
        case .aac:
            outputSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: aacBitRate,
            ]
        case .wav:
            outputSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false,
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

        writerLock.lock()
        assetWriter = writer
        assetWriterInput = nil               // built in delegate on first sample
        pendingOutputSettings = outputSettings
        pendingFileURL = fileURL
        consecutiveWriteErrors = 0
        consecutiveDropCount = 0
        didAppendAtLeastOneSample = false
        hasWarnedDroppedFrame = false
        writerLock.unlock()

        // Open the crash-recovery sidecar immediately so even a crash before
        // the first CMSampleBuffer leaves a recoverable artifact on disk.
        let provisionalRate = provisionalSidecarSampleRate()
        let sidecar = PCMSidecar(mainOutput: fileURL, sampleRate: provisionalRate, channels: 1)
        writerLock.lock()
        pcmSidecar = sidecar
        writerLock.unlock()

        if sidecar == nil {
            logger.warning("PCMSidecar init failed — this recording has no crash-recovery safety net.")
            DispatchQueue.main.async { self.sidecarUnavailable = true }
        } else {
            DispatchQueue.main.async { self.sidecarUnavailable = false }
        }

        recordingInputDeviceUID = currentInput?.device.uniqueID
        disconnectStopPending = false
        isRecording = true
    }

    /// True while a take is in progress — used by RecorderViewModel.reset()
    /// to abandon stale engine state without deleting recovery files.
    var isRecordingActive: Bool { isRecording }

    /// Drop stale recording state when the UI resets after an error. Closes
    /// the sidecar without deleting it so launch-time recovery still works.
    func abandonStaleRecordingState() {
        guard isRecording else { return }
        isRecording = false
        recordingInputDeviceUID = nil
        disconnectStopPending = false
        interruptionWatchdog?.cancel()
        interruptionWatchdog = nil
        DispatchQueue.main.async {
            self.sessionInterrupted = false
            self.writeIndicatorClearWork?.cancel()
            self.isWritingData = false
            self.sidecarUnavailable = false
            self.droppedFrameWarning = false
        }
        writerQueue.sync {}
        writerLock.lock()
        pcmSidecar?.close()
        assetWriterInput?.markAsFinished()
        assetWriter?.cancelWriting()
        assetWriter = nil
        assetWriterInput = nil
        pcmSidecar = nil
        pendingOutputSettings = nil
        pendingFileURL = nil
        writerLock.unlock()
    }

    /// Best-guess sample rate for the provisional sidecar header, taken from
    /// the bound capture device's active format before the first buffer arrives.
    private func provisionalSidecarSampleRate() -> Double {
        guard let desc = currentInput?.device.activeFormat.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else {
            return 48_000
        }
        return asbd.mSampleRate
    }

    /// Abort the in-progress recording without finalizing. cancelWriting()
    /// deletes the partial output file. Used by the "Quit Without Saving"
    /// confirmation path.
    func cancelRecording(completion: @escaping () -> Void) {
        isRecording = false
        recordingInputDeviceUID = nil
        disconnectStopPending = false
        interruptionWatchdog?.cancel()
        interruptionWatchdog = nil
        DispatchQueue.main.async {
            self.sessionInterrupted = false
            self.sidecarUnavailable = false
            self.writeIndicatorClearWork?.cancel()
            self.isWritingData = false
            self.droppedFrameWarning = false
        }
        // Drain any delegate calls already in flight on writerQueue before
        // isRecording was cleared.
        writerQueue.sync {}

        writerLock.lock()
        let writer = assetWriter
        let input = assetWriterInput
        let sidecar = pcmSidecar
        assetWriter = nil
        assetWriterInput = nil
        pcmSidecar = nil
        pendingOutputSettings = nil
        pendingFileURL = nil
        writerLock.unlock()

        // If the writer never got a session started, calling cancelWriting()
        // is still safe — it just discards the (empty) output file.
        input?.markAsFinished()
        writer?.cancelWriting()
        sidecar?.discard()

        DispatchQueue.main.async {
            completion()
        }
    }

    /// Stop the recording, finalize the writer, and report the resulting
    /// file URL via the completion. Three outcomes are possible:
    ///   • Writer wrote at least one sample → finishWriting, success
    ///   • First sample never arrived → silent discard, success(nil)
    ///   • Writer is in an error state    → failure with reason
    func stopRecording(completion: @escaping (Result<URL?, Error>) -> Void) {
        isRecording = false
        recordingInputDeviceUID = nil
        disconnectStopPending = false
        interruptionWatchdog?.cancel()
        interruptionWatchdog = nil
        DispatchQueue.main.async {
            self.sessionInterrupted = false
            self.sidecarUnavailable = false
            self.writeIndicatorClearWork?.cancel()
            self.isWritingData = false
            self.droppedFrameWarning = false
        }
        // Drain any delegate calls already in flight on writerQueue before
        // isRecording was cleared, so the snapshot we take below sees
        // the writer in its final state.
        writerQueue.sync {}

        writerLock.lock()
        let writer = assetWriter
        let input = assetWriterInput
        let sidecar = pcmSidecar
        let didAppend = didAppendAtLeastOneSample
        assetWriter = nil
        assetWriterInput = nil
        pcmSidecar = nil
        pendingOutputSettings = nil
        pendingFileURL = nil
        writerLock.unlock()

        guard let writer = writer else {
            sidecar?.close()
            DispatchQueue.main.async {
                completion(.failure(RecordingError.noActiveRecording))
            }
            return
        }

        // No samples ever arrived — first-sample path never ran, no input
        // was added to the writer, no session was started. Cancel the
        // writer (it's still in .unknown), discard the sidecar (if any),
        // return .success(nil) so the VM treats it as "nothing to do".
        if !didAppend || input == nil {
            logger.info("stopRecording with zero samples appended — silently discarding")
            sidecar?.discard()
            writer.cancelWriting()
            DispatchQueue.main.async { completion(.success(nil)) }
            return
        }

        // We have at least one appended sample — finalize normally.
        input?.markAsFinished()
        writer.finishWriting {
            DispatchQueue.main.async {
                if writer.status == .completed {
                    sidecar?.discard()
                    completion(.success(writer.outputURL))
                } else {
                    sidecar?.close()
                    let reason = writer.error?.localizedDescription ?? "status \(writer.status.rawValue)"
                    completion(.failure(RecordingError.writerFinishedWithError(reason)))
                }
            }
        }
    }

    /// Drop a stuck `isRecording` flag when the writer is already gone. After
    /// a writer tear-down the UI may leave `.recording` before the engine flag
    /// clears, which would otherwise block input changes via `setDevice`.
    func clearStaleRecordingSessionIfNeeded() {
        guard isRecording else { return }
        writerLock.lock()
        let writerGone = assetWriter == nil
        writerLock.unlock()
        guard writerGone else { return }
        logger.warning("Clearing stale isRecording flag — writer already gone")
        isRecording = false
        recordingInputDeviceUID = nil
        disconnectStopPending = false
        interruptionWatchdog?.cancel()
        interruptionWatchdog = nil
        DispatchQueue.main.async {
            self.sessionInterrupted = false
            self.writeIndicatorClearWork?.cancel()
            self.isWritingData = false
            self.sidecarUnavailable = false
            self.droppedFrameWarning = false
        }
    }

    func setDevice(_ device: AVCaptureDevice) {
        clearStaleRecordingSessionIfNeeded()
        guard !isRecording else {
            logger.info("Refusing device switch during active recording")
            return
        }
        guard let id = audioDeviceID(forUID: device.uniqueID) else {
            logger.error("Failed to translate device UID to AudioDeviceID: \(device.uniqueID, privacy: .public)")
            return
        }

        // Pre-check: does this device actually have input streams?
        //
        // The old AVAudioEngine code path had AUHAL silently fall back to a
        // previously-bound device when asked to bind to one with no input
        // streams (output-only devices, aggregate devices whose sub-devices
        // have no input, broken virtuals). AVCaptureSession surfaces this
        // more honestly (init AVCaptureDeviceInput throws), but the
        // pre-check is still worth keeping because the error path here is
        // cheaper than tearing down the session to discover the same fact.
        if !deviceHasInputStreams(id) {
            logger.info("Selected device has no input streams — refusing switch: \(device.localizedName, privacy: .public)")
            DispatchQueue.main.async { self.selectedDeviceUsable = false }
            return
        }
        DispatchQueue.main.async { self.selectedDeviceUsable = true }

        // Change the macOS system default input device so other apps that
        // honor the system default follow our pick. AVCaptureSession itself
        // binds the device directly (not via the system default), so the
        // setSystemDefault call is purely for cross-app consistency.
        //
        // Then rebuild the session bound to the explicit AVCaptureDevice.
        // No AUHAL race here — AVCaptureSession's device-binding does not
        // share the AVAudioEngine.connect format-mismatch surface that made
        // the old code path require multi-retry warm-up.
        _ = setSystemDefaultInputDevice(id)
        rebuildSession(with: device, intendedDeviceID: id)
    }

    /// Read the current macOS system-wide default input device via
    /// CoreAudio. Returned for diagnostic comparisons — AVCaptureSession
    /// binds the device we hand it directly (no reliance on the system
    /// default), but `setDevice` updates the system default for
    /// cross-app consistency, and some virtual devices accept that call
    /// with no error while CoreAudio quietly leaves the property at its
    /// previous value. Returns nil on query failure.
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
    /// Returns true on success. AVCaptureSession does not use this when
    /// binding our own AVCaptureDeviceInput, but we call it from
    /// `setDevice` for cross-app consistency (other apps that honor the
    /// system default follow our pick).
    ///
    /// Caveat: returning true does NOT guarantee CoreAudio actually applied
    /// the change. Some virtual devices accept the call (no error) but
    /// CoreAudio silently leaves the system default at its previous value.
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
    /// avoid false rejections — better to let AVCaptureSession try and
    /// surface its own error than to block a device because we couldn't
    /// enumerate.
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


// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate


extension AudioEngine: AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Called on `writerQueue` (set via setSampleBufferDelegate). One call
    /// per audio packet from AVCaptureAudioDataOutput. CMSampleBuffers flow
    /// directly into AVAssetWriterInput.append — no PCM conversion, no
    /// AVAudioPCMBuffer intermediate, no AVAudioConverter.
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Live peak-hold meter, always — independent of recording state.
        updateMeterLevels(from: sampleBuffer)

        guard isRecording else { return }

        writerLock.lock()
        guard let writer = assetWriter else {
            writerLock.unlock()
            return
        }

        // First-sample path: now that we know the source format, build the
        // AVAssetWriterInput with `sourceFormatHint`, add it to the writer,
        // start the writing session, and refine the provisional sidecar rate.
        var sidecarRateUpdate: Double?
        if assetWriterInput == nil {
            guard let outputSettings = pendingOutputSettings,
                  let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                writerLock.unlock()
                return
            }
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: outputSettings,
                sourceFormatHint: formatDesc
            )
            input.expectsMediaDataInRealTime = true

            guard writer.canAdd(input) else {
                tearDownWriterLocked(reason: "AVAssetWriter rejected the configured input")
                return
            }
            writer.add(input)

            guard writer.startWriting() else {
                let reason = writer.error?.localizedDescription ?? "startWriting failed"
                tearDownWriterLocked(reason: reason)
                return
            }
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: startTime)
            assetWriterInput = input

            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                sidecarRateUpdate = asbd.pointee.mSampleRate
            }
        }

        guard let input = assetWriterInput else {
            writerLock.unlock()
            return
        }

        guard writer.status == .writing else {
            let reason = writer.error?.localizedDescription ?? "AVAssetWriter status \(writer.status.rawValue)"
            tearDownWriterLocked(reason: reason)
            return
        }

        // Drop sample on backpressure when the writer ring is briefly
        // closed — but sustained drops mean audio is being lost, so fail
        // the take once the threshold is hit (same as consecutive writes).
        guard input.isReadyForMoreMediaData else {
            consecutiveDropCount += 1
            // Warn the user on the first drop of this take. The latch
            // prevents re-publishing on every subsequent drop in the same run;
            // it is reset in startRecording for the next take.
            if !hasWarnedDroppedFrame {
                hasWarnedDroppedFrame = true
                DispatchQueue.main.async { [weak self] in self?.droppedFrameWarning = true }
            }
            if consecutiveDropCount >= writeErrorThreshold {
                tearDownWriterLocked(reason: "Recording stopped: disk or encoder could not keep up (audio was being dropped)")
            } else {
                writerLock.unlock()
            }
            return
        }

        if input.append(sampleBuffer) {
            didAppendAtLeastOneSample = true
            consecutiveWriteErrors = 0
            consecutiveDropCount = 0
            let sidecar = pcmSidecar
            let rateUpdate = sidecarRateUpdate
            writerLock.unlock()
            if let rate = rateUpdate {
                sidecar?.updateSampleRateIfNeeded(rate)
            }
            sidecar?.append(sampleBuffer: sampleBuffer)
            DispatchQueue.main.async { [weak self] in
                self?.markDataFlowing()
            }
        } else {
            consecutiveWriteErrors += 1
            if consecutiveWriteErrors >= writeErrorThreshold {
                let reason = writer.error?.localizedDescription
                    ?? "AVAssetWriter status \(writer.status.rawValue)"
                tearDownWriterLocked(reason: reason)
            } else {
                writerLock.unlock()
            }
        }
    }

    /// Caller MUST hold writerLock. Clears writer state, cancels the
    /// partial main file, closes the sidecar so the recovery path can pick
    /// it up, ends the recording session, and delegates stop/finalize to
    /// RecorderViewModel (same path as device disconnect). Does not set
    /// lastError — the VM owns the user-facing message via stopRecording.
    private func tearDownWriterLocked(reason: String) {
        let writer = assetWriter
        let abortedSidecar = pcmSidecar
        let hadSamples = didAppendAtLeastOneSample
        let shouldNotifyVM = isRecording

        if shouldNotifyVM {
            isRecording = false
            recordingInputDeviceUID = nil
            disconnectStopPending = true
        }

        // Writer still has captured samples — leave refs intact so
        // stopRecording can finalize rather than losing the main file.
        if shouldNotifyVM && hadSamples && writer != nil {
            consecutiveWriteErrors = 0
            consecutiveDropCount = 0
            writerLock.unlock()
            logger.error("AVAssetWriter error — deferring finalize to stopRecording: \(reason, privacy: .public)")
            DispatchQueue.main.async {
                self.interruptionWatchdog?.cancel()
                self.interruptionWatchdog = nil
                self.sessionInterrupted = false
                self.writeIndicatorClearWork?.cancel()
                self.isWritingData = false
                self.onDisconnectedDuringRecording?("Recording stopped: \(reason)")
            }
            return
        }

        assetWriter = nil
        assetWriterInput = nil
        pcmSidecar = nil
        pendingOutputSettings = nil
        pendingFileURL = nil
        consecutiveWriteErrors = 0
        consecutiveDropCount = 0
        hasWarnedDroppedFrame = false
        writerLock.unlock()

        logger.error("AVAssetWriter tear-down: \(reason, privacy: .public)")
        abortedSidecar?.close()
        writer?.cancelWriting()
        guard shouldNotifyVM else { return }
        DispatchQueue.main.async {
            self.interruptionWatchdog?.cancel()
            self.interruptionWatchdog = nil
            self.sessionInterrupted = false
            self.writeIndicatorClearWork?.cancel()
            self.isWritingData = false
            self.onDisconnectedDuringRecording?("Recording stopped: \(reason)")
        }
    }

    /// Clear a published engine error without touching capture state.
    func clearLastError() {
        DispatchQueue.main.async { self.lastError = nil }
    }

    /// Peak-hold level and clip indicator from a CMSampleBuffer, published to the UI.
    private func updateMeterLevels(from sampleBuffer: CMSampleBuffer) {
        let peakLinear = peakLinear(from: sampleBuffer)
        if LevelMeter.isClipping(peakLinear: peakLinear) {
            indicateClipping()
        }
        let instantDb = LevelMeter.clampedDisplayDB(fromLinear: peakLinear)
        let coef = instantDb > smoothedPeakLevel ? LevelMeter.peakAttack : LevelMeter.peakRelease
        smoothedPeakLevel += coef * (instantDb - smoothedPeakLevel)
        let level = smoothedPeakLevel
        DispatchQueue.main.async { [weak self] in
            self?.meterLevel = level
        }
    }

    /// Light CLIP and schedule auto-clear; re-triggers extend the hold window.
    private func indicateClipping() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isClipping = true
            self.clipClearWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.isClipping = false
                self?.clipClearWork = nil
            }
            self.clipClearWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + LevelMeter.clipIndicatorHoldDuration,
                execute: work
            )
        }
    }

    /// Max absolute sample value (0…1+) across all channels in the buffer.
    private func peakLinear(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }
        var dataPointer: UnsafeMutablePointer<Int8>?
        var length = 0
        guard CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &dataPointer
        ) == kCMBlockBufferNoErr, let ptr = dataPointer, length > 0 else { return 0 }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            let floatCount = length / MemoryLayout<Float>.size
            guard floatCount > 0 else { return 0 }
            var peak: Float = 0
            ptr.withMemoryRebound(to: Float.self, capacity: floatCount) { floats in
                vDSP_maxmgv(floats, 1, &peak, vDSP_Length(floatCount))
            }
            return peak
        }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0

        if isFloat && asbd.mBitsPerChannel == 32 {
            let floatCount = length / MemoryLayout<Float>.size
            guard floatCount > 0 else { return 0 }
            var peak: Float = 0
            ptr.withMemoryRebound(to: Float.self, capacity: floatCount) { floats in
                vDSP_maxmgv(floats, 1, &peak, vDSP_Length(floatCount))
            }
            return peak
        }

        if isInt && asbd.mBitsPerChannel == 16 {
            let intCount = length / MemoryLayout<Int16>.size
            guard intCount > 0 else { return 0 }
            let ints = ptr.withMemoryRebound(to: Int16.self, capacity: intCount) { $0 }
            var peakSample: Int32 = 0
            for i in 0..<intCount {
                let absVal = Int32(abs(ints[i]))
                if absVal > peakSample { peakSample = absVal }
            }
            return Float(peakSample) / 32768.0
        }

        return 0
    }
}
