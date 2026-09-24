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
    ///
    /// The shared recorder saves to `UserDefaults.app`, which in a test run is
    /// a scratch suite. This used to check `UserDefaults.standard` — the
    /// developer's real domain, with the tests hosted by the app — so every
    /// run wrote "Ada Lovelace" over the developer's own guest name there.
    func testGuestNamePersistsAcrossLaunches() {
        let vm = RecorderViewModel.shared
        let original = vm.lastGuestName
        defer { vm.lastGuestName = original }

        vm.lastGuestName = "Ada Lovelace"
        XCTAssertEqual(
            UserDefaults.app.string(forKey: "lastGuestName"),
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

/// The tests run inside the app, so `UserDefaults.standard` here is the
/// developer's real settings. A test that reads or writes defaults passes a
/// suite of its own, removed in tearDown.
///
/// The suite is named by a path in a temporary folder. A suite named like a
/// bundle identifier lives in ~/Library/Preferences, and removing its domain
/// empties the file but leaves it there, matching the io.github.sevmorris.*
/// pattern the App Preferences source backs up. Deleting the file in tearDown
/// does not hold: cfprefsd writes it back after the test has finished.
/// Deleting a folder of our own does.
final class RecorderDefaultsTests: XCTestCase {
    private var folder: URL!
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("doublender-defaults-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suiteName = folder.appendingPathComponent("defaults").path
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        try super.tearDownWithError()
    }

    func testATestRunDoesNotGetTheRealDefaults() {
        XCTAssertTrue(AppLauncher.isHostingTests)
        XCTAssertFalse(UserDefaults.app === UserDefaults.standard)
    }

    /// Run at every launch, before the recorder exists — and so, before the
    /// launch checked for tests, at the start of every test run too.
    func testEraseSessionDefaultsClearsOnlyTheSessionSettings() {
        defaults.set("Custom take", forKey: "filenameBase")
        defaults.set("wav", forKey: "outputFormat")

        RecorderViewModel.eraseSessionDefaults(in: defaults)

        XCTAssertNil(defaults.string(forKey: "filenameBase"))
        XCTAssertEqual(defaults.string(forKey: "outputFormat"), "wav",
                       "The output format is sticky and must survive a launch")
    }
}
