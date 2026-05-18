import Foundation
import AVFoundation
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
            return "Cannot add AAC audio input to asset writer."
        case .writerFailedToStart(let reason):
            return "AVAssetWriter failed to start: \(reason)"
        case .noActiveRecording:
            return "Stop called without an active recording."
        case .writerFinishedWithError(let reason):
            return "Recording could not be finalized: \(reason)"
        }
    }
}

class AudioEngine: NSObject, ObservableObject {
    @Published var availableInputDevices: [AVCaptureDevice] = []
    @Published var selectedInputDevice: AVCaptureDevice?

    @Published var rmsLevel: Float = 0.0     // smoothed RMS, normalized 0...1 over -60..0 dBFS
    @Published var peakLevel: Float = 0.0    // peak with hold + dB-domain decay, normalized 0...1
    @Published var clipDetected: Bool = false  // latches when samples cross limiter ceiling
    @Published var lastError: String?

    private let meterFloorDb: Float = -60
    private let limiterCeilingLinear: Float = 0.891  // -1 dBFS — matches LookaheadLimiter
    private let rmsAttackSec: Float = 0.04
    private let rmsReleaseSec: Float = 0.30
    private let peakDecayDbPerSec: Float = 20
    private let clipLatchSeconds: CFAbsoluteTime = 1.0
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
    private var consecutiveWriteErrors = 0
    private let writeErrorThreshold = 5
    private var limiter: LookaheadLimiter?

    private var heldPeakDb: Float = -60
    private var smoothedRmsDb: Float = -60
    private var peakHoldUntil: CFAbsoluteTime = 0
    private var clipHoldUntil: CFAbsoluteTime = 0
    private let peakHoldSeconds: CFAbsoluteTime = 1.0
    private var lastMeterUpdate: CFAbsoluteTime = 0

    override init() {
        super.init()
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

        guard let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hwFormat.sampleRate, channels: hwFormat.channelCount, interleaved: false) else {
            let message = "Could not create tap format for selected input."
            DispatchQueue.main.async { self.lastError = message }
            return
        }
        
        currentTapFormat = tapFormat

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] (buffer, _) in
            guard let self = self else { return }
            self.updateMetersAndClip(buffer: buffer)
            self.appendBufferToWriter(buffer)
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
            // Recording in progress — save what we have, then surface the error.
            stopRecording { [weak self] result in
                guard let self else { return }
                let msg: String
                switch result {
                case .success:
                    msg = "Recording device disconnected. Your recording was saved."
                case .failure:
                    msg = "Recording device disconnected. The recording could not be saved."
                }
                DispatchQueue.main.async { self.lastError = msg }
            }
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
        if selectedInputDevice == nil {
            selectedInputDevice = AVCaptureDevice.default(for: .audio)
        }
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
            try? FileManager.default.removeItem(at: fileURL)
        }

        let fileType: AVFileType
        let outputSettings: [String: Any]
        switch format {
        case .aac:
            fileType = .m4a
            outputSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: tapFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: aacBitRate
            ]
        case .wav:
            // 32-bit float PCM matches our source sample format exactly, so
            // AVAssetWriter passes samples through with no conversion.
            fileType = .wav
            outputSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: tapFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: true,
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

        // Mirror the post-limiter mono stream so an unfinalized .m4a can
        // still be recovered. A nil sidecar (I/O failure) is non-fatal —
        // the recording proceeds without the safety net.
        let sidecar = PCMSidecar(mainOutput: fileURL, sampleRate: tapFormat.sampleRate, channels: 1)

        writerLock.lock()
        assetWriter = writer
        assetWriterInput = input
        pcmSidecar = sidecar
        writerFrameCount = 0
        limiter = LookaheadLimiter(sampleRate: tapFormat.sampleRate, channels: Int(tapFormat.channelCount))
        consecutiveWriteErrors = 0
        writerLock.unlock()

        isRecording = true
    }

    /// Abort the in-progress recording without finalizing. `cancelWriting()`
    /// deletes the partial output file. Used by the "Quit Without Saving"
    /// confirmation path.
    func cancelRecording(completion: @escaping () -> Void) {
        isRecording = false

        writerLock.lock()
        let writer = assetWriter
        let sidecar = pcmSidecar
        assetWriter = nil
        assetWriterInput = nil
        pcmSidecar = nil
        limiter = nil
        writerLock.unlock()

        sidecar?.discard()
        writer?.cancelWriting()
        DispatchQueue.main.async {
            completion()
        }
    }

    private func appendBufferToWriter(_ buffer: AVAudioPCMBuffer) {
        writerLock.lock()

        guard let writerInput = assetWriterInput, writerInput.isReadyForMoreMediaData else {
            writerLock.unlock()
            return
        }

        // Limiter runs inside the lock — limiter is created/destroyed under writerLock.
        limiter?.process(buffer: buffer)

        guard let monoBuffer = downmixToMono(buffer) else {
            consecutiveWriteErrors += 1
            writerLock.unlock()
            return
        }

        // Mirror to the sidecar before building the CMSampleBuffer — this
        // way the recovery copy captures audio even if sample-buffer
        // construction or the writer append fails.
        if let mono = monoBuffer.floatChannelData?[0] {
            pcmSidecar?.append(mono, frameCount: Int(monoBuffer.frameLength))
        }

        guard let sampleBuffer = makeSampleBuffer(from: monoBuffer, startFrame: writerFrameCount) else {
            consecutiveWriteErrors += 1
            writerLock.unlock()
            return
        }

        if writerInput.append(sampleBuffer) {
            writerFrameCount += Int64(monoBuffer.frameLength)
            consecutiveWriteErrors = 0
            writerLock.unlock()
        } else {
            consecutiveWriteErrors += 1
            if consecutiveWriteErrors >= writeErrorThreshold {
                // Capture and clear writer state so no further appends occur.
                let failedWriter = assetWriter
                let err = assetWriter?.error?.localizedDescription
                    ?? "status \(assetWriter?.status.rawValue ?? -1)"
                assetWriter = nil
                assetWriterInput = nil
                limiter = nil
                // Keep the sidecar on disk — the partial .m4a is being
                // cancelled, so the sidecar is the only recoverable copy.
                let abortedSidecar = pcmSidecar
                pcmSidecar = nil
                consecutiveWriteErrors = 0
                writerLock.unlock()

                abortedSidecar?.close()
                // Cancel the partial file — it can't be finalized in this state.
                failedWriter?.cancelWriting()
                DispatchQueue.main.async {
                    self.lastError = "AVAssetWriter rejected audio samples (\(err))."
                }
            } else {
                writerLock.unlock()
            }
        }
    }

    private func downmixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channelCount = Int(buffer.format.channelCount)
        if channelCount == 1 { return buffer }

        guard let inputChannels = buffer.floatChannelData,
              let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: buffer.format.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) else {
            return nil
        }
        monoBuffer.frameLength = buffer.frameLength

        guard let outputChannel = monoBuffer.floatChannelData?[0] else { return nil }

        let frameCount = Int(buffer.frameLength)
        let scale = 1.0 / Float(channelCount)
        for i in 0..<frameCount {
            var sum: Float = 0
            for c in 0..<channelCount {
                sum += inputChannels[c][i]
            }
            outputChannel[i] = sum * scale
        }
        return monoBuffer
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
    
    private func updateMetersAndClip(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        var sumSquares: Float = 0
        var peakLin: Float = 0
        var ceilingHit = false
        let ceiling = limiterCeilingLinear

        for c in 0..<channelCount {
            let data = channelData[c]
            for i in 0..<frameCount {
                let s = data[i]
                sumSquares += s * s
                let a = abs(s)
                if a > peakLin { peakLin = a }
                if a >= ceiling { ceilingHit = true }
            }
        }

        let frameTotal = Float(frameCount * channelCount)
        let rmsLin = sqrt(sumSquares / frameTotal)
        let rawRmsDb  = rmsLin  > 1e-6 ? 20 * log10(rmsLin)  : meterFloorDb
        let rawPeakDb = peakLin > 1e-6 ? 20 * log10(peakLin) : meterFloorDb

        let now = CFAbsoluteTimeGetCurrent()
        let dt: Float
        if lastMeterUpdate == 0 {
            dt = 0
            smoothedRmsDb = rawRmsDb
            heldPeakDb = rawPeakDb
        } else {
            dt = Float(now - lastMeterUpdate)
        }
        lastMeterUpdate = now

        // RMS — asymmetric one-pole in dB space.
        let rmsCoeff: Float = rawRmsDb > smoothedRmsDb
            ? expf(-dt / rmsAttackSec)
            : expf(-dt / rmsReleaseSec)
        smoothedRmsDb = rmsCoeff * smoothedRmsDb + (1 - rmsCoeff) * rawRmsDb
        smoothedRmsDb = max(meterFloorDb, smoothedRmsDb)

        // Peak — instant rise, hold, then dB-rate decay.
        if rawPeakDb >= heldPeakDb {
            heldPeakDb = rawPeakDb
            peakHoldUntil = now + peakHoldSeconds
        } else if now > peakHoldUntil {
            heldPeakDb = max(meterFloorDb, heldPeakDb - peakDecayDbPerSec * dt)
        }

        let rmsNorm  = max(0, min(1, (smoothedRmsDb - meterFloorDb) / -meterFloorDb))
        let peakNorm = max(0, min(1, (heldPeakDb  - meterFloorDb) / -meterFloorDb))

        if ceilingHit {
            clipHoldUntil = now + clipLatchSeconds
        }
        let clip = now < clipHoldUntil

        DispatchQueue.main.async {
            self.rmsLevel = rmsNorm
            self.peakLevel = peakNorm
            if self.clipDetected != clip { self.clipDetected = clip }
        }
    }
    
    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        isRecording = false

        writerLock.lock()
        let writer = assetWriter
        let input = assetWriterInput
        let sidecar = pcmSidecar
        assetWriter = nil
        assetWriterInput = nil
        pcmSidecar = nil
        limiter = nil
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
        let deviceUID = device.uniqueID
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var uidString: CFString = deviceUID as CFString
        var audioDeviceID: AudioDeviceID = 0
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        let status = withUnsafePointer(to: &uidString) { ptr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                UInt32(MemoryLayout<CFString>.size),
                ptr,
                &deviceIDSize,
                &audioDeviceID
            )
        }
        
        if status == noErr {
            rebuildEngine(with: audioDeviceID)
        } else {
            logger.error("Failed to translate device UID to AudioDeviceID (status: \(status, privacy: .public))")
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
