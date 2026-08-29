import XCTest
@testable import DoublEnder

final class RecorderViewModelTests: XCTestCase {

    func testResetReturnsToReadyState() {
        let vm = RecorderViewModel.shared
        vm.state = .error("Test error")
        vm.reset()
        if case .ready = vm.state {
            // expected
        } else {
            XCTFail("Expected .ready after reset(), got \(vm.state)")
        }
    }

    // MARK: - Guest name

    /// The one piece of the withdrawn auto-record work that was worth keeping:
    /// the name persists, so a returning guest confirms rather than retypes.
    func testGuestNamePersistsAcrossLaunches() {
        let vm = RecorderViewModel.shared
        let original = vm.lastGuestName
        defer { vm.lastGuestName = original }

        vm.lastGuestName = "Ada Lovelace"
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "lastGuestName"),
            "Ada Lovelace",
            "The name must reach UserDefaults, not just the view model"
        )
    }

    func testNoActiveRecordingErrorIsFinalizationRace() {
        let error = RecordingError.noActiveRecording
        XCTAssertEqual(
            error.errorDescription,
            "Stop called without an active recording."
        )
    }
}
