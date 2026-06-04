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

    func testNoActiveRecordingErrorIsFinalizationRace() {
        let error = RecordingError.noActiveRecording
        XCTAssertEqual(
            error.errorDescription,
            "Stop called without an active recording."
        )
    }
}
