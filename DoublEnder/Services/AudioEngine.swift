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

    private var isRecording = false
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var pcmSidecar: PCMSidecar?
    private let writerLock = NSLock()
    /// uniqueID → kind, rebuilt on each device refresh so the picker
    /// doesn't re-query CoreAudio on every SwiftUI render.
    private var deviceKindCache: [String: InputDeviceKind] = [:]
    private var consecutiveWriteErrors = 0
    private let writeErrorThreshold = 5

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

    func start() {
        if audioEngine?.isRunning == true { return }
        rebuildEngine(with: nil)
    }
    
    /// Indicator: 150 ms tail after the most recent successful write.
    private func markDataFlowing() {
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
