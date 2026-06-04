import XCTest
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
        frameCount: Int
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
            presentationTimeStamp: .zero,
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
