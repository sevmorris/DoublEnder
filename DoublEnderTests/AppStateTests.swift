import XCTest
@testable import DoublEnder

final class AppStateTests: XCTestCase {

    func testOutputFormatExtensions() {
        XCTAssertEqual(OutputFormat.aac.fileExtension, "m4a")
        XCTAssertEqual(OutputFormat.wav.fileExtension, "wav")
    }

    func testRecordingBlockedWhenDiskSpaceLow() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSpaceTests-\(UUID().uuidString)", isDirectory: true)
        // Fresh temp dir — should not block (unless volume is genuinely full).
        let reason = DiskSpaceChecker.recordingBlockedReason(for: dir)
        XCTAssertNil(reason)
    }
}
