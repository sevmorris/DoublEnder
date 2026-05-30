import XCTest
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
