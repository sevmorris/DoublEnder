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
}
