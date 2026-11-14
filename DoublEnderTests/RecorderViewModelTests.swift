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

    // MARK: - Whether RECORD can start a take

    /// On a first launch the system's microphone question can sit unanswered,
    /// and the engine, which has built nothing yet, still calls itself healthy.
    /// RECORD then led to the name prompt and "Audio engine is not running".
    func testNoTakeStartsWhileTheMicrophoneIsStillBeingAskedFor() {
        XCTAssertFalse(RecorderViewModel.canStart(askingForMicrophone: true, startPending: false,
                                                  engineHealthy: true, deviceUsable: true, rebuilding: false))
        XCTAssertTrue(RecorderViewModel.canStart(askingForMicrophone: false, startPending: false,
                                                 engineHealthy: true, deviceUsable: true, rebuilding: false))
    }

    func testEachReasonAloneKeepsATakeFromStarting() {
        typealias Row = (asking: Bool, pending: Bool, healthy: Bool, usable: Bool, rebuilding: Bool)
        let rows: [Row] = [
            (true, false, true, true, false),
            (false, true, true, true, false),
            (false, false, false, true, false),
            (false, false, true, false, false),
            (false, false, true, true, true),
        ]
        for row in rows {
            XCTAssertFalse(RecorderViewModel.canStart(askingForMicrophone: row.asking, startPending: row.pending,
                                                      engineHealthy: row.healthy, deviceUsable: row.usable,
                                                      rebuilding: row.rebuilding), "\(row)")
        }
    }

    /// A take that waited for the session to be rebuilt starts when it is. If
    /// the rebuild failed, the engine has said why and a start would put "not
    /// running" over that; if it never finished, the start fails as it used to.
    func testATakeThatWaitedForARebuildStartsOnlyOnAWorkingSession() {
        XCTAssertTrue(RecorderViewModel.shouldStart(afterWaitRebuilt: true, canStart: true))
        XCTAssertFalse(RecorderViewModel.shouldStart(afterWaitRebuilt: true, canStart: false))
        XCTAssertTrue(RecorderViewModel.shouldStart(afterWaitRebuilt: false, canStart: false))
    }

    // MARK: - Which USB input is offered

    func testAUSBInputIsOfferedUnlessThereIsNothingToOffer() {
        XCTAssertTrue(RecorderViewModel.isWorthOffering(uid: "usb", selected: "built-in", dismissed: [], isDockPort: false))
        // Already the input.
        XCTAssertFalse(RecorderViewModel.isWorthOffering(uid: "usb", selected: "usb", dismissed: [], isDockPort: false))
        // A dock's audio port delivers noise with nothing plugged into it.
        XCTAssertFalse(RecorderViewModel.isWorthOffering(uid: "usb", selected: "built-in", dismissed: [], isDockPort: true))
        // "Keep Current", earlier this session.
        XCTAssertFalse(RecorderViewModel.isWorthOffering(uid: "usb", selected: "built-in", dismissed: ["usb"], isDockPort: false))
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

/// What the user is told when a stop fails, decided from the files on disk
/// rather than a capture session.
final class StopFailureMessageTests: XCTestCase {
    private var folder: URL!
    private let reason = "Recording stopped: AVAssetWriter rejected the configured input"

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("doublender-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        try super.tearDownWithError()
    }

    /// A writer torn down on its first buffer leaves the sidecar holding only
    /// its header, and launch recovery deletes that without a word. This said
    /// the audio was safe and asked the user to relaunch to recover it.
    func testHeaderOnlySidecarMeansNoAudioWasCaptured() throws {
        let main = folder.appendingPathComponent("Take.m4a")
        let sidecar = try XCTUnwrap(PCMSidecar(mainOutput: main, sampleRate: 48_000, channels: 1))
        sidecar.close()

        XCTAssertEqual(
            RecorderViewModel.stopFailureMessage(
                for: RecordingError.noActiveRecording, mainOutput: main, disconnectReason: reason
            ),
            "\(reason). No audio was captured — try again with another input."
        )
    }

    /// The same words the no-samples stop (`.success(.none)`) uses.
    func testNothingCapturedMatchesTheNoSamplesStop() {
        let main = folder.appendingPathComponent("Take.m4a")
        XCTAssertEqual(
            RecorderViewModel.stopFailureMessage(
                for: RecordingError.noActiveRecording, mainOutput: main, disconnectReason: reason
            ),
            RecorderViewModel.noAudioCapturedMessage(reason: reason)
        )
        XCTAssertEqual(
            RecorderViewModel.stopFailureMessage(
                for: RecordingError.noActiveRecording, mainOutput: main, disconnectReason: nil
            ),
            "No audio was captured — try again with another input."
        )
    }

    func testSidecarWithAudioIsSafe() throws {
        let main = folder.appendingPathComponent("Take.m4a")
        let sidecar = try XCTUnwrap(PCMSidecar(mainOutput: main, sampleRate: 48_000, channels: 1))
        var sample: Float = 0.25
        sidecar.append(&sample, frameCount: 1)
        sidecar.close()

        XCTAssertEqual(
            RecorderViewModel.stopFailureMessage(
                for: RecordingError.writerFinishedWithError("disk full"),
                mainOutput: main, disconnectReason: nil
            ),
            "Recording was interrupted but your audio is safe. "
                + "Quit and relaunch DoublEnder to recover it as a WAV file."
        )
    }

    /// Audio went to the writer, which could not finish, and there is no
    /// sidecar to fall back on: the error itself is the message.
    func testFinalizeFailureWithNothingToRecoverReportsTheError() {
        let main = folder.appendingPathComponent("Take.m4a")
        XCTAssertEqual(
            RecorderViewModel.stopFailureMessage(
                for: RecordingError.writerFinishedWithError("disk full"),
                mainOutput: main, disconnectReason: nil
            ),
            "Failed to finalize recording: Recording could not be finalized: disk full"
        )
    }
}

/// The input the guest chose, and USB inputs that turn up during a take.
final class InputChoiceTests: XCTestCase {

    /// The chosen input comes back only when nothing would be cut short.
    func testTheChosenInputComesBackOnlyBetweenTakes() {
        XCTAssertTrue(RecorderViewModel.mayReturnToChosenInput(recording: false, finalizing: false,
                                                               starting: false, rebuilding: false))
        XCTAssertFalse(RecorderViewModel.mayReturnToChosenInput(recording: true, finalizing: false,
                                                                starting: false, rebuilding: false), "during a take")
        XCTAssertFalse(RecorderViewModel.mayReturnToChosenInput(recording: false, finalizing: true,
                                                                starting: false, rebuilding: false), "while it is saved")
        XCTAssertFalse(RecorderViewModel.mayReturnToChosenInput(recording: false, finalizing: false,
                                                                starting: true, rebuilding: false), "RECORD waiting")
        XCTAssertFalse(RecorderViewModel.mayReturnToChosenInput(recording: false, finalizing: false,
                                                                starting: false, rebuilding: true), "mid-rebuild")
    }

    func testTheFaceplateSaysTheInputCameBack() {
        XCTAssertEqual(RecorderViewModel.returnedInputNotice("Shure MV7"), "Back on Shure MV7")
    }

    /// Only the guest's own pick counts, and a later pick wins. The launch's
    /// built-in default is not a choice. No capture session is involved: a
    /// pick of a UID no device has changes nothing but the choice.
    func testAChoiceIsTheGuestsLatestPick() {
        let vm = RecorderViewModel.shared
        let before = vm.selectedInputDeviceID
        defer { vm.selectedInputDeviceID = before }
        vm.chooseInput("first-pick")
        vm.chooseInput("second-pick")
        XCTAssertEqual(vm.chosenInputUID, "second-pick")
    }
}
