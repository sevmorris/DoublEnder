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

    // MARK: - Auto-record

    /// Fresh install must arm. Absent key != off, which is why the restore
    /// reads the object rather than `bool(forKey:)`.
    func testAutoRecordDefaultsOnWhenNoStoredPreference() {
        UserDefaults.standard.removeObject(forKey: "autoRecordEnabled")
        let vm = RecorderViewModel.shared
        vm.autoRecordEnabled = true
        XCTAssertTrue(vm.autoRecordEnabled)
    }

    func testDisablingAutoRecordPersistsAndClearsCountdown() {
        let vm = RecorderViewModel.shared
        vm.autoRecordEnabled = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "autoRecordEnabled"))
        XCTAssertNil(vm.autoRecordCountdown, "Disabling must stop any running countdown")
        vm.autoRecordEnabled = true
    }

    /// Cancelling is scoped to the launch: it must not write the persisted
    /// switch, or a one-off "not now" would silently become "never".
    func testCancelIsSessionScopedAndDoesNotPersist() {
        let vm = RecorderViewModel.shared
        vm.autoRecordEnabled = true
        vm.cancelAutoRecord()
        XCTAssertNil(vm.autoRecordCountdown)
        XCTAssertTrue(
            vm.autoRecordEnabled,
            "Cancel must leave the persisted switch alone"
        )
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "autoRecordEnabled"))
    }

    /// The window has to outlast a USB interface enumerating and the switch
    /// prompt being read — the take is bound to whatever mic wins that race.
    func testCountdownIsLongEnoughForDeviceSelectionToSettle() {
        XCTAssertGreaterThanOrEqual(RecorderViewModel.autoRecordCountdownSeconds, 10)
    }

    /// The regression that hung DoublEnderCloudTests for seven minutes: the
    /// test host launches the real app, and a launch-time dialog has nobody to
    /// answer it. If this ever returns false in a test run, verify-cloud.sh
    /// and release-cloud.sh hang instead of failing.
    func testAutoRecordIsSuppressedUnderTests() {
        XCTAssertTrue(RecorderViewModel.isRunningUnderTests)
    }

    /// The prompt must never fire on its own: no arming means no dialog, and
    /// no dialog means capture cannot begin without an explicit Start.
    func testNoCountdownRunsWhileUnderTest() {
        XCTAssertNil(RecorderViewModel.shared.autoRecordCountdown)
    }

    /// The notice is presented from the arming path, so the test-host guard is
    /// the only thing keeping it out of xcodebuild. If it ever fires here it
    /// blocks the run exactly as the record prompt once did.
    func testFirstRunNoticeNeverFiresUnderTests() {
        XCTAssertTrue(RecorderViewModel.isRunningUnderTests)
        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: "autoRecordNoticeShown"),
            "A test run must not consume the one-time notice"
        )
    }

    /// Declining and starting are distinct cases by construction — the earlier
    /// optional-of-optional shape let "declined" read as "start unnamed".
    func testDeclineIsDistinguishableFromStartingUnnamed() {
        let declined = AutoRecordDecision.decline
        let unnamed = AutoRecordDecision.start(name: nil)
        if case .decline = declined {} else { XCTFail("decline must be decline") }
        if case .start(let n) = unnamed { XCTAssertNil(n) } else { XCTFail("start must be start") }
    }

    func testNoActiveRecordingErrorIsFinalizationRace() {
        let error = RecordingError.noActiveRecording
        XCTAssertEqual(
            error.errorDescription,
            "Stop called without an active recording."
        )
    }
}
