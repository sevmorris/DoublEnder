import XCTest
@testable import DoublEnder

final class AppStateTests: XCTestCase {

    func testOutputFormatExtensions() {
        XCTAssertEqual(OutputFormat.aac.fileExtension, "m4a")
        XCTAssertEqual(OutputFormat.wav.fileExtension, "wav")
    }

    func testMinimumFreeBytesScalesWithFormat() {
        XCTAssertLessThan(
            DiskSpaceChecker.minimumFreeBytes(for: .aac),
            DiskSpaceChecker.minimumFreeBytes(for: .wav)
        )
    }

    func testRecordingBlockedWhenDiskSpaceLow() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSpaceTests-\(UUID().uuidString)", isDirectory: true)
        let reason = DiskSpaceChecker.recordingBlockedReason(for: dir, format: .aac)
        XCTAssertNil(reason)
    }
}
