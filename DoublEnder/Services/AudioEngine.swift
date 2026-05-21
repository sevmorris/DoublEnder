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

    private let aacBitRate: Int = 256_000

    private var audioEngine: AVAudioEngine?
    private var engineConfigObserver: NSObjectProtocol?
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
    }

    @objc private func handleRefreshTrigger() {
        guard !isRecording else { return }
        refreshDevices()
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
            engine.inputNode.removeTap(onBus: 0)
            audioEngine = nil
        }

        let newEngine = AVAudioEngine()
        
        if let deviceID = deviceID {
            do {
                // Must be called before accessing inputNode for the first time or before prepare
                try newEngine.inputNode.auAudioUnit.setDeviceID(deviceID)
            } catch {
                logger.error("Failed to set device ID: \(error.localizedDescription, privacy: .public)")
            }
        }
        
        let inputNode = newEngine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)

        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            let message = "Selected input device reports no usable format (channels=\(hwFormat.channelCount), rate=\(hwFormat.sampleRate))."
            DispatchQueue.main.async { self.lastError = message }
            return
        }

        // M5: flag sample rates ≤ 16 kHz — almost always Bluetooth SCO (8 kHz)
        // or a misconfigured device. Doesn't block recording; just surfaces the
        // warning so the user can switch to a better input.
        let isLowQuality = hwFormat.sampleRate <= 16_000
        if isLowQuality {
            logger.warning("Input rate \(hwFormat.sampleRate, privacy: .public) Hz — possible Bluetooth SCO or low-quality device.")
        }
        DispatchQueue.main.async { self.lowQualityInput = isLowQuality }

        guard let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hwFormat.sampleRate, channels: hwFormat.channelCount, interleaved: false) else {
            let message = "Could not create tap format for selected input."
            DispatchQueue.main.async { self.lastError = message }
            return
        }
        
        currentTapFormat = tapFormat

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] (buffer, _) in
            guard let self = self else { return }
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
        if selectedInputDevice == nil {
            selectedInputDevice = AVCaptureDevice.default(for: .audio)
        }
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
            // 32-bit signed integer PCM — maximally compatible with
            // AVAssetWriter's WAV container. The writer converts the float32
            // CMSampleBuffers we supply; no lossless quality is sacrificed
            // since int32 range fully covers the 24-bit source depth of any
            // real-world interface. Float32 WAV causes canAdd() to return false
            // on some macOS versions.
            fileType = .wav
            outputSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: encoderRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
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
