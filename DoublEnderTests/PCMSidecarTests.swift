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

    /// Two channels mix as AVAssetWriter mixes the main file: each scaled by
    /// 1/√2 and summed (see the writer tests below), not averaged.
    func testNormalizedMonoFloatSamplesInt24StereoMixesLikeTheWriter() throws {
        // 2 stereo frames. Frame 1: (+max, -max) → ~0. Frame 2: (0, +max) → max × 0.707.
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
        let gain = Float(0.5).squareRoot()
        let frame1Expected = (Float(8_388_607) / 8_388_608.0 + Float(-8_388_608) / 8_388_608.0) * gain
        let frame2Expected = (0 + Float(8_388_607) / 8_388_608.0) * gain
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

    func testNormalizedMonoFloatSamplesInt32StereoMixesLikeTheWriter() throws {
        // 2 stereo frames. Frame 1: (max, min) → ~0. Frame 2: (0, max) → ~0.707.
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
        let gain = Float(0.5).squareRoot()
        let frame1Expected = (Float(Int32.max) / divisor + Float(Int32.min) / divisor) * gain
        let frame2Expected = (0 + Float(Int32.max) / divisor) * gain
        XCTAssertEqual(result?[0] ?? -99, frame1Expected, accuracy: 1e-6)
        XCTAssertEqual(result?[1] ?? -99, frame2Expected, accuracy: 1e-6)
    }

    /// Planar input used to give channel 0 alone, so a mic on channel 1 of a
    /// planar device never reached the meter.
    func testNormalizedMonoFloatSamplesPlanarStereoMixesBothChannels() throws {
        let buffer = try makePlanarFloatSampleBuffer(channels: [[0.5, -0.25], [0.25, 0.25]])
        let result = PCMSidecar.normalizedMonoFloatSamples(from: buffer)
        XCTAssertEqual(result?.count, 2)
        let gain = Float(0.5).squareRoot()
        XCTAssertEqual(result?[0] ?? -99, 0.75 * gain, accuracy: 1e-6)
        XCTAssertEqual(result?[1] ?? -99, 0, accuracy: 1e-6)
    }

    // MARK: - The writer's mono mix

    // AVAssetWriter makes the main file mono itself. These write multichannel
    // takes through it with the app's WAV settings and require
    // normalizedMonoFloatSamples, which feeds the meter and the sidecar, to
    // reach the file's peak within 0.1 dB. Averaging the two channels of an
    // unlabelled pair read 3 dB under the file. They also catch Apple
    // changing the writer's mix.

    func testMixMatchesWriterWithToneOnOneChannel() throws {
        try assertMixMatchesWriter(
            try interleavedToneBuffers(peaks: [0.5, 0]), fileName: "left.wav"
        )
    }

    func testMixMatchesWriterWithToneOnTheOtherChannel() throws {
        try assertMixMatchesWriter(
            try interleavedToneBuffers(peaks: [0, 0.5]), fileName: "right.wav"
        )
    }

    func testMixMatchesWriterWithToneOnBothChannels() throws {
        try assertMixMatchesWriter(
            try interleavedToneBuffers(peaks: [0.5, 0.5]), fileName: "both.wav"
        )
    }

    func testMixMatchesWriterForPlanarChannels() throws {
        try assertMixMatchesWriter(
            try planarToneBuffers(left: 0.25, right: 0.5), fileName: "planar.wav"
        )
    }

    /// The writer mixes by channel label (`PCMSidecar.writerMixGains`). Every
    /// layout the mixer claims to know, with a tone on each channel alone and
    /// on all of them, at a level that keeps every mix below full scale.
    func testMixMatchesWriterForEachMeasuredLayout() throws {
        func labelled(_ labels: AudioChannelLabel...) -> Data {
            channelLayout(tag: kAudioChannelLayoutTag_UseChannelDescriptions, labels: labels)
        }
        let layouts: [(name: String, channels: Int, layout: Data?)] = [
            ("unlabelled mono", 1, nil),
            ("mono labelled left", 1, labelled(kAudioChannelLabel_Left)),
            ("mono labelled discrete 1", 1, labelled(kAudioChannelLabel_Discrete_1)),
            ("Stereo", 2, channelLayout(tag: kAudioChannelLayoutTag_Stereo)),
            ("StereoHeadphones", 2, channelLayout(tag: kAudioChannelLayoutTag_StereoHeadphones)),
            ("Binaural", 2, channelLayout(tag: kAudioChannelLayoutTag_Binaural)),
            ("MidSide", 2, channelLayout(tag: kAudioChannelLayoutTag_MidSide)),
            ("left, right", 2, labelled(kAudioChannelLabel_Left, kAudioChannelLabel_Right)),
            ("left, right bitmap", 2,
             channelLayout(tag: kAudioChannelLayoutTag_UseChannelBitmap, bitmap: [.bit_Left, .bit_Right])),
            ("surrounds", 2, labelled(kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround)),
            ("centre, unknown", 2, labelled(kAudioChannelLabel_Center, kAudioChannelLabel_Unknown)),
            ("mono, mono", 2, labelled(kAudioChannelLabel_Mono, kAudioChannelLabel_Mono)),
            ("unused", 2, labelled(kAudioChannelLabel_Unused, kAudioChannelLabel_Unused)),
            ("DiscreteInOrder 2", 2, channelLayout(tag: kAudioChannelLayoutTag_DiscreteInOrder | 2)),
            ("discrete 1, 0", 2, labelled(kAudioChannelLabel_Discrete_1, kAudioChannelLabel_Discrete_0)),
            ("left, discrete 1", 2, labelled(kAudioChannelLabel_Left, kAudioChannelLabel_Discrete_1)),
            ("Quadraphonic", 4, channelLayout(tag: kAudioChannelLayoutTag_Quadraphonic)),
            ("DiscreteInOrder 4", 4, channelLayout(tag: kAudioChannelLayoutTag_DiscreteInOrder | 4)),
            ("discrete 0 to 3", 4, labelled(
                kAudioChannelLabel_Discrete_0, kAudioChannelLabel_Discrete_1,
                kAudioChannelLabel_Discrete_2, kAudioChannelLabel_Discrete_3
            )),
        ]
        for (index, entry) in layouts.enumerated() {
            var patterns = (0..<entry.channels).map { lit in
                (0..<entry.channels).map { $0 == lit ? 0.25 : 0 }
            }
            if entry.channels > 1 {
                patterns.append([Double](repeating: 0.25, count: entry.channels))
            }
            for (pattern, peaks) in patterns.enumerated() {
                try assertMixMatchesWriter(
                    try interleavedToneBuffers(peaks: peaks, layout: entry.layout),
                    fileName: "layout-\(index)-\(pattern).wav",
                    context: "\(entry.name), tone peaks \(peaks)"
                )
            }
        }
    }

    /// With no layout, more than two channels mix as they did before the
    /// mixer followed the writer, whose mix of them hasn't been measured.
    func testMoreThanTwoUnlabelledChannelsAreAveraged() throws {
        // One frame: +max, 0, -max/2 (as close as 24 bits allow).
        let bytes: [UInt8] = [
            0xFF, 0xFF, 0x7F,   // +8388607
            0x00, 0x00, 0x00,   // 0
            0x00, 0x00, 0xC0,   // -4194304
        ]
        let buffer = try makePCMSampleBuffer(
            bytes: bytes, channels: 3, bitsPerChannel: 24, frameCount: 1
        )
        let result = PCMSidecar.normalizedMonoFloatSamples(from: buffer)
        XCTAssertEqual(result?.count, 1)
        let expected = (Float(8_388_607) / 8_388_608.0 + 0 - 0.5) / 3
        XCTAssertEqual(result?[0] ?? -99, expected, accuracy: 1e-6)
    }

    /// Build an interleaved little-endian signed-integer PCM CMSampleBuffer.
    /// `channelLayout`, if given, labels the channels in the format
    /// description, as a capture format may (see `channelLayout(tag:labels:)`).
    private func makePCMSampleBuffer(
        bytes: [UInt8],
        channels: UInt32,
        bitsPerChannel: UInt32,
        frameCount: Int,
        presentationTimeStamp: CMTime = .zero,
        channelLayout: Data? = nil
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
        let layoutBytes = channelLayout ?? Data()
        let formatStatus = layoutBytes.withUnsafeBytes { layout in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: layout.count,
                layout: layout.isEmpty ? nil : layout.baseAddress?.assumingMemoryBound(to: AudioChannelLayout.self),
                magicCookieSize: 0, magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDesc
            )
        }
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

    /// Write `buffers` through AVAssetWriter as the app writes a WAV, and
    /// require the mix `normalizedMonoFloatSamples` makes of them to peak
    /// where the file does.
    private func assertMixMatchesWriter(
        _ buffers: [CMSampleBuffer], fileName: String, context: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let filePeak = try writerMonoPeak(of: buffers, fileName: fileName)
        let mixPeak = buffers
            .compactMap { PCMSidecar.normalizedMonoFloatSamples(from: $0) }
            .map { LevelMeter.peakLinear(in: $0) }
            .max() ?? 0
        guard filePeak > 1e-4 else {
            XCTAssertLessThan(
                mixPeak, 1e-4, "\(context): the writer dropped the tone and the mix kept \(mixPeak)",
                file: file, line: line
            )
            return
        }
        XCTAssertEqual(
            20 * log10f(mixPeak / filePeak), 0, accuracy: 0.1,
            "\(context): the file peaks at \(filePeak) and the mix at \(mixPeak)",
            file: file, line: line
        )
    }

    /// Peak of the mono WAV AVAssetWriter makes of `buffers`, written with the
    /// app's WAV settings (`AudioEngine.startRecording`, at the source rate the
    /// capture delegate fills in) and the first buffer's format as the
    /// `sourceFormatHint`, as the capture delegate builds its writer input.
    private func writerMonoPeak(of buffers: [CMSampleBuffer], fileName: String) throws -> Float {
        let first = try XCTUnwrap(buffers.first)
        let formatDesc = try XCTUnwrap(CMSampleBufferGetFormatDescription(first))
        let rate = try XCTUnwrap(
            CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee.mSampleRate
        )
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let url = tempDir.appendingPathComponent(fileName)
        let writer = try AVAssetWriter(outputURL: url, fileType: .wav)
        let input = AVAssetWriterInput(
            mediaType: .audio, outputSettings: settings, sourceFormatHint: formatDesc
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw NSError(domain: "PCMSidecarTests", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "The writer refused the input"])
        }
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "startWriting: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(first))
        for buffer in buffers {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            XCTAssertTrue(input.append(buffer), "append: \(String(describing: writer.error))")
        }
        input.markAsFinished()
        let done = expectation(description: "finishWriting")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(writer.status, .completed, "finishWriting: \(String(describing: writer.error))")

        let audioFile = try AVAudioFile(forReading: url)
        XCTAssertEqual(audioFile.fileFormat.channelCount, 1)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: AVAudioFrameCount(audioFile.length)
        ))
        try audioFile.read(into: pcm)
        let samples = try XCTUnwrap(pcm.floatChannelData?[0])
        return LevelMeter.peakLinear(in: Array(UnsafeBufferPointer(start: samples, count: Int(pcm.frameLength))))
    }

    /// One second of a 1 kHz tone as 48 kHz interleaved Int24, the shape a USB
    /// interface delivers, peaking on each channel at the matching entry of
    /// `peaks`. `layout`, if given, labels the channels.
    private func interleavedToneBuffers(
        peaks: [Double], layout: Data? = nil
    ) throws -> [CMSampleBuffer] {
        let rate = 48_000
        let frameStride = peaks.count * 3
        var buffers: [CMSampleBuffer] = []
        var written = 0
        while written < rate {
            let n = min(1024, rate - written)
            var bytes = [UInt8](repeating: 0, count: n * frameStride)
            for i in 0..<n {
                let s = sin(2 * Double.pi * 1_000 * Double(written + i) / Double(rate))
                for (channel, peak) in peaks.enumerated() {
                    let v = Int32((s * peak * 8_388_607).rounded())
                    let offset = i * frameStride + channel * 3
                    bytes[offset] = UInt8(truncatingIfNeeded: v)
                    bytes[offset + 1] = UInt8(truncatingIfNeeded: v >> 8)
                    bytes[offset + 2] = UInt8(truncatingIfNeeded: v >> 16)
                }
            }
            buffers.append(try makePCMSampleBuffer(
                bytes: bytes, channels: UInt32(peaks.count), bitsPerChannel: 24, frameCount: n,
                presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: 48_000),
                channelLayout: layout
            ))
            written += n
        }
        return buffers
    }

    /// An AudioChannelLayout's bytes, for a format description: `tag`, and
    /// one channel description per entry of `labels` (for
    /// `kAudioChannelLayoutTag_UseChannelDescriptions`).
    private func channelLayout(
        tag: AudioChannelLayoutTag, labels: [AudioChannelLabel] = [],
        bitmap: AudioChannelBitmap = []
    ) -> Data {
        let descriptionsOffset = MemoryLayout<AudioChannelLayout>
            .offset(of: \AudioChannelLayout.mChannelDescriptions) ?? 12
        let descriptionSize = MemoryLayout<AudioChannelDescription>.stride
        let size = max(
            MemoryLayout<AudioChannelLayout>.size,
            descriptionsOffset + labels.count * descriptionSize
        )
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let layout = base.assumingMemoryBound(to: AudioChannelLayout.self)
            layout.pointee.mChannelLayoutTag = tag
            layout.pointee.mChannelBitmap = bitmap
            layout.pointee.mNumberChannelDescriptions = UInt32(labels.count)
            for (i, label) in labels.enumerated() {
                (base + descriptionsOffset + i * descriptionSize).storeBytes(
                    of: AudioChannelDescription(
                        mChannelLabel: label, mChannelFlags: [], mCoordinates: (0, 0, 0)
                    ),
                    as: AudioChannelDescription.self
                )
            }
        }
        return data
    }

    /// The same tone as two-channel planar Float32, CoreAudio's own layout.
    private func planarToneBuffers(left: Float, right: Float) throws -> [CMSampleBuffer] {
        let rate = 48_000
        var buffers: [CMSampleBuffer] = []
        var written = 0
        while written < rate {
            let n = min(1024, rate - written)
            let tone = (0..<n).map { i in
                Float(sin(2 * Double.pi * 1_000 * Double(written + i) / Double(rate)))
            }
            buffers.append(try makePlanarFloatSampleBuffer(
                channels: [tone.map { $0 * left }, tone.map { $0 * right }],
                presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: 48_000)
            ))
            written += n
        }
        return buffers
    }

    /// Build a 48 kHz planar Float32 CMSampleBuffer, one plane per channel,
    /// from an AVAudioPCMBuffer, as CoreAudio lays planar audio out.
    private func makePlanarFloatSampleBuffer(
        channels: [[Float]], presentationTimeStamp: CMTime = .zero
    ) throws -> CMSampleBuffer {
        let frameCount = try XCTUnwrap(channels.first?.count)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: AVAudioChannelCount(channels.count), interleaved: false
        ))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)
        ))
        pcm.frameLength = AVAudioFrameCount(frameCount)
        let planes = try XCTUnwrap(pcm.floatChannelData)
        for (channel, samples) in channels.enumerated() {
            for (i, sample) in samples.enumerated() { planes[channel][i] = sample }
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format.formatDescription,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer else {
            throw NSError(domain: "PCMSidecarTests", code: Int(createStatus))
        }
        let dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
            bufferList: pcm.audioBufferList
        )
        guard dataStatus == noErr else {
            throw NSError(domain: "PCMSidecarTests", code: Int(dataStatus))
        }
        if !CMSampleBufferDataIsReady(sampleBuffer) {
            CMSampleBufferSetDataReady(sampleBuffer)
        }
        return sampleBuffer
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
