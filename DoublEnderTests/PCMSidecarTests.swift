import XCTest
import AVFoundation
import CoreMedia
import CoreAudio
@testable import DoublEnder

final class PCMSidecarTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PCMSidecarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Int24 / Int32 normalization

    func testNormalizedMonoFloatSamplesInt24Mono() throws {
        // Three little-endian 24-bit samples: 0, +max (0x7FFFFF), -max (0x800000)
        let bytes: [UInt8] = [
            0x00, 0x00, 0x00,   // 0
            0xFF, 0xFF, 0x7F,   // +8388607
            0x00, 0x00, 0x80,   // -8388608 (sign extended)
        ]
        let buffer = try makePCMSampleBuffer(
            bytes: bytes, channels: 1, bitsPerChannel: 24, frameCount: 3
        )
        let result = PCMSidecar.normalizedMonoFloatSamples(from: buffer)
        XCTAssertEqual(result?.count, 3)
        XCTAssertEqual(result?[0] ?? -99, 0.0, accuracy: 1e-6)
        XCTAssertEqual(result?[1] ?? -99, 8_388_607.0 / 8_388_608.0, accuracy: 1e-6)
        XCTAssertEqual(result?[2] ?? -99, -1.0, accuracy: 1e-6)
    }

    func testNormalizedMonoFloatSamplesInt24StereoAveragesChannels() throws {
        // 2 stereo frames. Frame 1: (+max, -max) → ~0. Frame 2: (0, +max) → max/2.
        let bytes: [UInt8] = [
            0xFF, 0xFF, 0x7F,   // L: +8388607
            0x00, 0x00, 0x80,   // R: -8388608
            0x00, 0x00, 0x00,   // L: 0
            0xFF, 0xFF, 0x7F,   // R: +8388607
        ]
        let buffer = try makePCMSampleBuffer(
            bytes: bytes, channels: 2, bitsPerChannel: 24, frameCount: 2
        )
        let result = PCMSidecar.normalizedMonoFloatSamples(from: buffer)
        XCTAssertEqual(result?.count, 2)
        let frame1Expected = (Float(8_388_607) / 8_388_608.0 + Float(-8_388_608) / 8_388_608.0) / 2
        let frame2Expected = (0 + Float(8_388_607) / 8_388_608.0) / 2
        XCTAssertEqual(result?[0] ?? -99, frame1Expected, accuracy: 1e-6)
        XCTAssertEqual(result?[1] ?? -99, frame2Expected, accuracy: 1e-6)
    }

    func testNormalizedMonoFloatSamplesInt32Mono() throws {
        // Three little-endian 32-bit samples: 0, Int32.max, Int32.min
        let bytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x00,   // 0
            0xFF, 0xFF, 0xFF, 0x7F,   // Int32.max
            0x00, 0x00, 0x00, 0x80,   // Int32.min
        ]
        let buffer = try makePCMSampleBuffer(
            bytes: bytes, channels: 1, bitsPerChannel: 32, frameCount: 3
        )
        let result = PCMSidecar.normalizedMonoFloatSamples(from: buffer)
        XCTAssertEqual(result?.count, 3)
        XCTAssertEqual(result?[0] ?? -99, 0.0, accuracy: 1e-6)
        XCTAssertEqual(result?[1] ?? -99, 1.0, accuracy: 1e-6)
        // Int32.min / Int32.max is slightly more negative than -1 (asymmetric range)
        XCTAssertEqual(result?[2] ?? -99, Float(Int32.min) / Float(Int32.max), accuracy: 1e-6)
    }

    func testNormalizedMonoFloatSamplesInt32StereoAveragesChannels() throws {
        // 2 stereo frames. Frame 1: (max, min) → ~0. Frame 2: (0, max) → ~0.5.
        let bytes: [UInt8] = [
            0xFF, 0xFF, 0xFF, 0x7F,   // L: Int32.max
            0x00, 0x00, 0x00, 0x80,   // R: Int32.min
            0x00, 0x00, 0x00, 0x00,   // L: 0
            0xFF, 0xFF, 0xFF, 0x7F,   // R: Int32.max
        ]
        let buffer = try makePCMSampleBuffer(
            bytes: bytes, channels: 2, bitsPerChannel: 32, frameCount: 2
        )
        let result = PCMSidecar.normalizedMonoFloatSamples(from: buffer)
        XCTAssertEqual(result?.count, 2)
        let divisor = Float(Int32.max)
        let frame1Expected = (Float(Int32.max) / divisor + Float(Int32.min) / divisor) / 2
        let frame2Expected = (0 + Float(Int32.max) / divisor) / 2
        XCTAssertEqual(result?[0] ?? -99, frame1Expected, accuracy: 1e-6)
        XCTAssertEqual(result?[1] ?? -99, frame2Expected, accuracy: 1e-6)
    }

    /// Build an interleaved little-endian signed-integer PCM CMSampleBuffer.
    private func makePCMSampleBuffer(
        bytes: [UInt8],
        channels: UInt32,
        bitsPerChannel: UInt32,
        frameCount: Int,
        presentationTimeStamp: CMTime = .zero
    ) throws -> CMSampleBuffer {
        let bytesPerSample = bitsPerChannel / 8
        let bytesPerFrame = channels * bytesPerSample

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: bitsPerChannel,
            mReserved: 0
        )

        var formatDesc: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard formatStatus == noErr, let formatDesc else {
            throw NSError(domain: "PCMSidecarTests", code: Int(formatStatus))
        }

        let dataLength = bytes.count
        guard let memoryBlock = malloc(dataLength) else {
            throw NSError(domain: "PCMSidecarTests", code: -1)
        }
        bytes.withUnsafeBytes { src in
            if let base = src.baseAddress {
                memoryBlock.copyMemory(from: base, byteCount: dataLength)
            }
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: memoryBlock,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorMalloc,   // CMBlockBuffer will free() it
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            free(memoryBlock)
            throw NSError(domain: "PCMSidecarTests", code: Int(blockStatus))
        }

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(frameCount),
            presentationTimeStamp: presentationTimeStamp,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer else {
            throw NSError(domain: "PCMSidecarTests", code: Int(sbStatus))
        }
        return sampleBuffer
    }

    func testRecoverToWAVProducesValidRIFF() throws {
        let mainOutput = tempDir.appendingPathComponent("DoublEnder_test.m4a")
        guard let sidecar = PCMSidecar(mainOutput: mainOutput, sampleRate: 48_000, channels: 1) else {
            XCTFail("PCMSidecar init failed")
            return
        }

        let samples: [Float] = [0, 0.25, -0.25, 0.5, -0.5, 0.1, -0.1, 0]
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            sidecar.append(base, frameCount: samples.count)
        }
        sidecar.close()

        let recovered = try PCMSidecar.recoverToWAV(sidecarURL: sidecar.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.path))

        let data = try Data(contentsOf: recovered)
        XCTAssertGreaterThanOrEqual(data.count, 44)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertTrue(recovered.lastPathComponent.hasSuffix(".wav"))
    }

    func testRecoverDEP1LegacySidecar() throws {
        let sidecarURL = tempDir.appendingPathComponent("legacy.m4a.pcmrec")
        var header = Data("DEP1".utf8)
        var rate = Double(44_100).bitPattern.littleEndian
        var ch = UInt32(1).littleEndian
        withUnsafeBytes(of: &rate) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &ch) { header.append(contentsOf: $0) }
        try header.write(to: sidecarURL)

        let handle = try FileHandle(forWritingTo: sidecarURL)
        try handle.seekToEnd()
        let samples: [Float] = [0.1, -0.1, 0.2]
        let payload = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try handle.write(contentsOf: payload)
        try handle.close()

        let recovered = try PCMSidecar.recoverToWAV(sidecarURL: sidecarURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.path))
        let data = try Data(contentsOf: recovered)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
    }

    func testRecoverTruncatedSidecarStillProducesWAV() throws {
        let mainOutput = tempDir.appendingPathComponent("truncated.m4a")
        guard let sidecar = PCMSidecar(mainOutput: mainOutput, sampleRate: 48_000, channels: 1) else {
            XCTFail("PCMSidecar init failed")
            return
        }
        let samples: [Float] = [0.5, -0.5]
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            sidecar.append(base, frameCount: samples.count)
        }
        // Simulate crash — close without finalize on main writer.
        sidecar.close()

        let recovered = try PCMSidecar.recoverToWAV(sidecarURL: sidecar.url)
        let data = try Data(contentsOf: recovered)
        // 44-byte header + 2 float samples.
        XCTAssertEqual(data.count, 44 + samples.count * MemoryLayout<Float>.size)
    }

    func testHasRecoverableContentRejectsHeaderOnly() throws {
        let mainOutput = tempDir.appendingPathComponent("empty.m4a")
        guard let sidecar = PCMSidecar(mainOutput: mainOutput, sampleRate: 48_000, channels: 1) else {
            XCTFail("PCMSidecar init failed")
            return
        }
        sidecar.close()
        XCTAssertFalse(PCMSidecar.hasRecoverableContent(at: sidecar.url))
    }

    func testHasRecoverableContentAcceptsPayload() throws {
        let mainOutput = tempDir.appendingPathComponent("payload.m4a")
        guard let sidecar = PCMSidecar(mainOutput: mainOutput, sampleRate: 48_000, channels: 1) else {
            XCTFail("PCMSidecar init failed")
            return
        }
        var sample: Float = 0.25
        sidecar.append(&sample, frameCount: 1)
        sidecar.close()
        XCTAssertTrue(PCMSidecar.hasRecoverableContent(at: sidecar.url))
    }

    func testRecoverToWAVRejectsEmptyPayload() throws {
        let mainOutput = tempDir.appendingPathComponent("header_only.m4a")
        guard let sidecar = PCMSidecar(mainOutput: mainOutput, sampleRate: 48_000, channels: 1) else {
            XCTFail("PCMSidecar init failed")
            return
        }
        sidecar.close()

        XCTAssertThrowsError(try PCMSidecar.recoverToWAV(sidecarURL: sidecar.url)) { error in
            guard case PCMSidecar.RecoveryError.emptyPayload = error else {
                XCTFail("Expected emptyPayload, got \(error)")
                return
            }
        }
    }

    func testRecoverToWAVRejectsCorruptHeader() throws {
        let badSidecar = tempDir.appendingPathComponent("bad.m4a.pcmrec")
        try Data("NOTA".utf8).write(to: badSidecar)

        XCTAssertThrowsError(try PCMSidecar.recoverToWAV(sidecarURL: badSidecar)) { error in
            guard case PCMSidecar.RecoveryError.badHeader = error else {
                XCTFail("Expected badHeader, got \(error)")
                return
            }
        }
    }

    func testMainOutputURLStripsSidecarExtension() {
        let sidecar = tempDir.appendingPathComponent("Take_2026.m4a.pcmrec")
        let main = PCMSidecar.mainOutputURL(for: sidecar)
        XCTAssertEqual(main.lastPathComponent, "Take_2026.m4a")
    }

    func testMainFileValidThresholdBytes() {
        XCTAssertEqual(PCMSidecar.mainFileValidThresholdBytes, 8 * 1024)
    }

    func testRecoveryModelDetectsValidMainFile() throws {
        let mainURL = tempDir.appendingPathComponent("saved.m4a")
        let sidecarURL = tempDir.appendingPathComponent("saved.m4a.pcmrec")
        try writeTake(to: mainURL, format: .aac, seconds: 1, finish: true)
        try Data("DEP2".utf8).write(to: sidecarURL)

        let model = RecoveryModel(sidecarURL: sidecarURL)
        XCTAssertTrue(model.hasValidMainFile)
    }

    /// The case the size threshold got backwards: a crashed take is well over
    /// 8 KB, so the dialog offered "Keep Saved" for a file that won't play,
    /// and keeping it deleted the only recoverable copy.
    func testRecoveryModelRejectsCrashedMainFile() throws {
        let mainURL = tempDir.appendingPathComponent("crashed.m4a")
        let sidecarURL = tempDir.appendingPathComponent("crashed.m4a.pcmrec")
        let writer = try writeTake(to: mainURL, format: .aac, seconds: 2, finish: false)
        defer { writer.cancelWriting() }
        try waitUntilLargerThanThreshold(mainURL)
        try Data("DEP2".utf8).write(to: sidecarURL)

        let model = RecoveryModel(sidecarURL: sidecarURL)
        XCTAssertFalse(model.hasValidMainFile)
    }

    func testRecoveryModelRejectsMissingMainFile() throws {
        let sidecarURL = tempDir.appendingPathComponent("gone.m4a.pcmrec")
        try Data("DEP2".utf8).write(to: sidecarURL)

        let model = RecoveryModel(sidecarURL: sidecarURL)
        XCTAssertFalse(model.hasValidMainFile)
    }

    // MARK: - Finished vs. crashed main files

    func testFinishedShortAACIsFinishedRecordingDespiteSize() throws {
        // A finished 0.1 s take is under 8 KB, so size called it a stub.
        let url = tempDir.appendingPathComponent("short.m4a")
        try writeTake(to: url, format: .aac, seconds: 0.1, finish: true)
        XCTAssertLessThan(try fileSize(url), PCMSidecar.mainFileValidThresholdBytes)
        XCTAssertTrue(RecoveryModel.isFinishedRecording(at: url))
    }

    func testCrashedAACIsNotFinishedRecording() throws {
        let url = tempDir.appendingPathComponent("crash.m4a")
        let writer = try writeTake(to: url, format: .aac, seconds: 2, finish: false)
        defer { writer.cancelWriting() }
        try waitUntilLargerThanThreshold(url)
        XCTAssertFalse(RecoveryModel.isFinishedRecording(at: url))
    }

    func testFinishedWAVIsFinishedRecording() throws {
        let url = tempDir.appendingPathComponent("done.wav")
        try writeTake(to: url, format: .wav, seconds: 0.5, finish: true)
        XCTAssertTrue(RecoveryModel.isFinishedRecording(at: url))
    }

    func testCrashedWAVIsNotFinishedRecording() throws {
        // All the audio is in the file, but the header still says zero bytes.
        let url = tempDir.appendingPathComponent("crash.wav")
        let writer = try writeTake(to: url, format: .wav, seconds: 1, finish: false)
        defer { writer.cancelWriting() }
        try waitUntilLargerThanThreshold(url)
        XCTAssertFalse(RecoveryModel.isFinishedRecording(at: url))
    }

    func testZeroFilledFileIsNotFinishedRecording() throws {
        let url = tempDir.appendingPathComponent("zeros.m4a")
        try Data(repeating: 0, count: Int(PCMSidecar.mainFileValidThresholdBytes) + 1).write(to: url)
        XCTAssertFalse(RecoveryModel.isFinishedRecording(at: url))
    }

    /// Write `seconds` of a 440 Hz tone as 48 kHz mono Int24 — the shape a USB
    /// interface delivers — through AVAssetWriter with the app's own output
    /// settings (`AudioEngine.startRecording`). Unless `finish` is set the
    /// writer is left open, which is the state a crash leaves the file in.
    @discardableResult
    private func writeTake(to url: URL, format: OutputFormat, seconds: Double,
                           finish: Bool) throws -> AVAssetWriter {
        let rate = 48_000.0
        let settings: [String: Any] = format == .aac
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 256_000]
            : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 24,
               AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsFloatKey: false,
               AVLinearPCMIsNonInterleaved: false]
        let writer = try AVAssetWriter(outputURL: url, fileType: format == .aac ? .m4a : .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "startWriting: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        let total = Int(seconds * rate)
        var written = 0
        var phase = 0.0
        while written < total {
            let n = min(1024, total - written)
            var bytes = [UInt8](repeating: 0, count: n * 3)
            for i in 0..<n {
                let v = Int32(sin(phase) * 0.25 * 8_388_607)
                phase += 2 * .pi * 440 / rate
                bytes[i * 3] = UInt8(truncatingIfNeeded: v)
                bytes[i * 3 + 1] = UInt8(truncatingIfNeeded: v >> 8)
                bytes[i * 3 + 2] = UInt8(truncatingIfNeeded: v >> 16)
            }
            let buffer = try makePCMSampleBuffer(
                bytes: bytes, channels: 1, bitsPerChannel: 24, frameCount: n,
                presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: 48_000)
            )
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            XCTAssertTrue(input.append(buffer), "append: \(String(describing: writer.error))")
            written += n
        }

        if finish {
            input.markAsFinished()
            let done = expectation(description: "finishWriting")
            writer.finishWriting { done.fulfill() }
            wait(for: [done], timeout: 10)
            XCTAssertEqual(writer.status, .completed, "finishWriting: \(String(describing: writer.error))")
        }
        return writer
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// An open writer flushes on its own schedule. Waiting for the file to
    /// pass the old threshold proves the test covers the case size misjudged.
    private func waitUntilLargerThanThreshold(_ url: URL) throws {
        let deadline = Date().addingTimeInterval(5)
        while (try? fileSize(url)) ?? 0 <= PCMSidecar.mainFileValidThresholdBytes && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertGreaterThan(try fileSize(url), PCMSidecar.mainFileValidThresholdBytes)
    }

    func testRecoveryModelRejectsStubMainFile() throws {
        let mainURL = tempDir.appendingPathComponent("stub.m4a")
        let sidecarURL = tempDir.appendingPathComponent("stub.m4a.pcmrec")
        try Data(repeating: 0, count: 64).write(to: mainURL)
        try Data("DEP2".utf8).write(to: sidecarURL)

        let model = RecoveryModel(sidecarURL: sidecarURL)
        XCTAssertFalse(model.hasValidMainFile)
    }

    func testUpdateSampleRateIfNeededRewritesHeader() throws {
        let mainOutput = tempDir.appendingPathComponent("rate_update.m4a")
        guard let sidecar = PCMSidecar(mainOutput: mainOutput, sampleRate: 48_000, channels: 1) else {
            XCTFail("PCMSidecar init failed")
            return
        }
        sidecar.updateSampleRateIfNeeded(44_100)
        var sample: Float = 0.1
        sidecar.append(&sample, frameCount: 1)
        sidecar.close()

        let parsed = try PCMSidecar.recoverToWAV(sidecarURL: sidecar.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parsed.path))
    }
}
