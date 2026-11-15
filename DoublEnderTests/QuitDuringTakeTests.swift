import AppKit
import XCTest
@testable import DoublEnder

/// The answer to "Recording in progress", when the take has ended meanwhile.
final class QuitDuringTakeTests: XCTestCase {

    func testWithTheTakeStillRunningTheAnswerIsCarriedOut() {
        XCTAssertEqual(QuitDuringTake.action(for: .alertFirstButtonReturn, takeInProgress: true), .stopThenQuit)
        XCTAssertEqual(QuitDuringTake.action(for: .alertSecondButtonReturn, takeInProgress: true), .discardThenQuit)
        XCTAssertEqual(QuitDuringTake.action(for: .alertThirdButtonReturn, takeInProgress: true), .stay)
    }

    /// The producer stopped it from the dashboard, or the microphone was
    /// unplugged, while the question was up. There is nothing left to stop,
    /// and nothing that should be deleted: the quit is decided afresh, and an
    /// upload under way gets its own question.
    func testWithTheTakeOverNeitherAnswerTouchesIt() {
        XCTAssertEqual(QuitDuringTake.action(for: .alertFirstButtonReturn, takeInProgress: false), .askAgain)
        XCTAssertEqual(QuitDuringTake.action(for: .alertSecondButtonReturn, takeInProgress: false), .askAgain)
    }

    func testCancelStaysWhateverHappenedToTheTake() {
        XCTAssertEqual(QuitDuringTake.action(for: .alertThirdButtonReturn, takeInProgress: false), .stay)
    }

    /// The question could not open: an update is replacing the app.
    func testNoAnswerStays() {
        XCTAssertEqual(QuitDuringTake.action(for: nil, takeInProgress: true), .stay)
        XCTAssertEqual(QuitDuringTake.action(for: nil, takeInProgress: false), .stay)
    }

    // MARK: - Cloud: staying open to upload

    /// The take uploads now: the app stays open for it, and quitting again
    /// asks about the upload.
    func testStopAndSaveStaysOpenWhileTheTakeUploads() {
        XCTAssertFalse(QuitDuringTake.quitsAfterStop(uploading: true, forSystem: false))
    }

    /// Nothing to upload (upload off, Local, nothing captured): it quits, as before.
    func testStopAndSaveQuitsWithNothingToUpload() {
        XCTAssertTrue(QuitDuringTake.quitsAfterStop(uploading: false, forSystem: false))
        XCTAssertTrue(QuitDuringTake.quitsAfterStop(uploading: false, forSystem: true))
    }

    /// A logout, restart or shutdown is not held up: the take is recorded as
    /// pending, and the next launch offers it.
    func testTheSystemQuittingIsNotHeldUp() {
        XCTAssertTrue(QuitDuringTake.quitsAfterStop(uploading: true, forSystem: true))
    }

    /// A logout, restart or shutdown during an upload goes ahead with no
    /// question; the next launch offers the take. It used to ask "Upload in
    /// progress", and Return (Keep Uploading) called the logout off.
    func testALogoutDuringAnUploadIsNotHeldUp() {
        XCTAssertEqual(QuitDuringTake.decision(question: .uploading, forSystem: true, asksAboutUploads: true), .quit)
    }

    /// A quit the guest asked for still asks about the upload; a take is asked
    /// about whoever quits, so Stop & Save can close its file.
    func testTheGuestsQuitStillAsks() {
        XCTAssertEqual(QuitDuringTake.decision(question: .uploading, forSystem: false, asksAboutUploads: true),
                       .askAboutUpload)
        XCTAssertEqual(QuitDuringTake.decision(question: .recording, forSystem: false, asksAboutUploads: true),
                       .askAboutRecording)
        XCTAssertEqual(QuitDuringTake.decision(question: .recording, forSystem: true, asksAboutUploads: true),
                       .askAboutRecording)
        XCTAssertEqual(QuitDuringTake.decision(question: nil, forSystem: false, asksAboutUploads: true), .quit)
        // Local uploads nothing, so it never asks about one.
        XCTAssertEqual(QuitDuringTake.decision(question: .uploading, forSystem: false, asksAboutUploads: false),
                       .quit)
    }

    func testOnlyTheSystemsReasonsCountAsTheSystemQuitting() {
        for reason in [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog,
                       kAERestart, kAEShutDown, kAEQuitAll] {
            XCTAssertTrue(QuitDuringTake.isSystemQuit(reason: reason), "\(reason)")
        }
        XCTAssertFalse(QuitDuringTake.isSystemQuit(reason: nil))
        XCTAssertFalse(QuitDuringTake.isSystemQuit(reason: kAEQuitApplication))
    }

    /// The question says what Stop & Save will do.
    func testTheQuestionSaysTheAppStaysOpenToUpload() {
        XCTAssertTrue(QuitDuringTake.message(appName: "DoublEnder Cloud", staysToUpload: true)
            .contains("DoublEnder Cloud stays open to upload it, then quits"))
        XCTAssertFalse(QuitDuringTake.message(appName: "DoublEnder", staysToUpload: false).contains("upload"))
    }

    /// The app stayed open for the upload: its confirmation says the app quits
    /// when it is dismissed, after whatever else it had to say.
    func testTheUploadedConfirmationSaysTheAppWillQuit() {
        let quit = "\(updaterAppName) quits when you click OK."
        XCTAssertEqual(RecorderViewModel.uploadedNote(nil, quitsAfter: true), quit)
        XCTAssertEqual(RecorderViewModel.uploadedNote("Your producer stopped this recording.", quitsAfter: true),
                       "Your producer stopped this recording.\n\(quit)")
        XCTAssertNil(RecorderViewModel.uploadedNote(nil, quitsAfter: false))
        XCTAssertEqual(RecorderViewModel.uploadedNote("note", quitsAfter: false), "note")
    }
}
