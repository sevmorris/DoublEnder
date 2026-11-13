import XCTest
@testable import DoublEnder

final class AppActivityTests: XCTestCase {

    func testNothingBlocksBeforeTheRecorderExists() {
        let activity = AppActivity()
        XCTAssertNil(activity.recorder, "asking must never build the recorder")
        XCTAssertTrue(activity.blockers.isEmpty)
        XCTAssertFalse(activity.blocksRelaunch)
        XCTAssertNil(activity.quitQuestion)
    }

    func testTheRecorderIsAskedEachTime() {
        let activity = AppActivity()
        var recorder: Set<AppActivity.Blocker> = []
        activity.recorder = { recorder }

        XCTAssertFalse(activity.blocksRelaunch)
        recorder = [.recording]
        XCTAssertEqual(activity.blockers, [.recording])
        XCTAssertEqual(activity.quitQuestion, .recording)
        recorder = [.uploading]
        XCTAssertEqual(activity.quitQuestion, .uploading)
        recorder = []
        XCTAssertFalse(activity.blocksRelaunch)
    }

    /// Two dialogs up, one closes: the other still counts.
    func testHeldBlockersCount() {
        let activity = AppActivity()
        activity.begin(.modal)
        activity.begin(.modal)
        activity.end(.modal)
        XCTAssertEqual(activity.blockers, [.modal])
        activity.end(.modal)
        XCTAssertTrue(activity.blockers.isEmpty)
        // One end too many must not let a later dialog go uncounted.
        activity.end(.modal)
        activity.begin(.modal)
        XCTAssertEqual(activity.blockers, [.modal])
    }

    /// A dialog or a conversion blocks an update, though a quit asks nothing
    /// about it: the person quitting has decided.
    func testADialogOrAConversionBlocksARelaunchButAsksNothingAtQuit() {
        for blocker in [AppActivity.Blocker.modal, .recovering] {
            let activity = AppActivity()
            activity.begin(blocker)
            XCTAssertTrue(activity.blocksRelaunch)
            XCTAssertNil(activity.quitQuestion)
        }
    }

    /// The property an update's quit rests on: whenever a quit would ask, a
    /// relaunch is blocked, so the update never gets as far as the question.
    /// Checked for every combination of blockers.
    func testWheneverAQuitWouldAskARelaunchIsBlocked() {
        let all = AppActivity.Blocker.allCases
        for mask in 0..<(1 << all.count) {
            let fromRecorder = Set(all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            for heldMask in 0..<(1 << all.count) {
                let activity = AppActivity()
                activity.recorder = { fromRecorder }
                for (index, blocker) in all.enumerated() where heldMask & (1 << index) != 0 {
                    activity.begin(blocker)
                }
                if activity.quitQuestion != nil {
                    XCTAssertTrue(activity.blocksRelaunch)
                }
                if !activity.blocksRelaunch {
                    XCTAssertNil(activity.quitQuestion)
                }
            }
        }
    }

    /// A take is asked about before an upload: the states exclude each other in
    /// the recorder, and if they ever did not, the take is what would be lost.
    func testATakeIsAskedAboutFirst() {
        let activity = AppActivity()
        activity.recorder = { [.recording, .uploading] }
        XCTAssertEqual(activity.quitQuestion, .recording)
    }

    /// A dialog does no work of its own, so it never stops a download.
    func testOnlyRealWorkBlocksHeavyWork() {
        for blocker in AppActivity.Blocker.allCases {
            let activity = AppActivity()
            activity.begin(blocker)
            XCTAssertEqual(activity.blocksHeavyWork, blocker != .modal, "\(blocker)")
        }
    }

    /// An update is replacing the app: a take started now would be cut off.
    func testNoTakeStartsWhileAnUpdateReplacesTheApp() {
        let vm = RecorderViewModel.shared
        vm.state = .ready
        AppActivity.shared.beginCommittingUpdate()
        defer { AppActivity.shared.endCommittingUpdate() }
        vm.startRecording()
        guard case .ready = vm.state else {
            return XCTFail("startRecording went ahead during an update: \(vm.state)")
        }
    }

    func testCommittingAnUpdateIsSetAndCleared() {
        let activity = AppActivity()
        XCTAssertFalse(activity.isCommittingUpdate)
        activity.beginCommittingUpdate()
        XCTAssertTrue(activity.isCommittingUpdate)
        activity.endCommittingUpdate()
        XCTAssertFalse(activity.isCommittingUpdate)
    }

    // MARK: - What the recorder reports

    func testTheRecorderBlocksWhileRecordingFinalizingOrUploading() {
        typealias Row = (recording: Bool, finalizing: Bool, uploading: Bool, expected: Set<AppActivity.Blocker>)
        let rows: [Row] = [
            (false, false, false, []),
            (true, false, false, [.recording]),
            // The file is still being closed, whatever the state says.
            (false, true, false, [.recording]),
            (true, true, false, [.recording]),
            (false, false, true, [.uploading]),
            (false, true, true, [.recording, .uploading]),
        ]
        for row in rows {
            XCTAssertEqual(
                RecorderViewModel.activityBlockers(isRecording: row.recording, isFinalizing: row.finalizing,
                                                   isUploading: row.uploading),
                row.expected, "\(row)")
        }
    }
}

final class ModalGateTests: XCTestCase {

    func testADialogCountsAsActivityWhileItIsUp() {
        let activity = AppActivity()
        XCTAssertFalse(ModalGate.isPresenting)

        let result = ModalGate.run(activity: activity) { () -> Int in
            XCTAssertTrue(ModalGate.isPresenting)
            XCTAssertEqual(activity.blockers, [.modal])
            return 7
        }

        XCTAssertEqual(result, 7)
        XCTAssertFalse(ModalGate.isPresenting)
        XCTAssertFalse(activity.blocksRelaunch)
    }

    /// The USB offer over the name prompt, or over the updater's dialog.
    func testAPromptIsDroppedWhileAnotherDialogIsUp() {
        let activity = AppActivity()
        var promptRan = false
        ModalGate.run(activity: activity) {
            let shown: Void? = ModalGate.run(.prompt, activity: activity) { promptRan = true }
            XCTAssertNil(shown)
        }
        XCTAssertFalse(promptRan)

        // With nothing else up, it opens.
        XCTAssertNotNil(ModalGate.run(.prompt, activity: activity) { promptRan = true })
        XCTAssertTrue(promptRan)
    }

    /// "Microphone disconnected" over the quit question: both have to be seen.
    func testARequiredDialogOpensOverAnother() {
        let activity = AppActivity()
        var innerRan = false
        ModalGate.run(activity: activity) {
            ModalGate.run(activity: activity) {
                innerRan = true
                XCTAssertEqual(ModalGate.depth, 2)
            }
            XCTAssertEqual(activity.blockers, [.modal], "the outer dialog is still up")
        }
        XCTAssertTrue(innerRan)
        XCTAssertEqual(ModalGate.depth, 0)
    }

    func testNothingOpensWhileAnUpdateReplacesTheApp() {
        let activity = AppActivity()
        activity.beginCommittingUpdate()
        var ran = false
        XCTAssertNil(ModalGate.run(activity: activity) { ran = true })
        XCTAssertNil(ModalGate.run(.prompt, activity: activity) { ran = true })
        XCTAssertFalse(ran)

        activity.endCommittingUpdate()
        XCTAssertNotNil(ModalGate.run(activity: activity) { ran = true })
        XCTAssertTrue(ran)
    }

    // MARK: - From async code

    /// The updater's dialogs come from a main actor task. Run straight from
    /// one, a modal stops the main queue (MainRunLoopTests); through here it
    /// does not.
    @MainActor
    func testADialogFromATaskLeavesTheMainQueueLive() {
        let activity = AppActivity()
        let done = expectation(description: "dialog closed")
        var serviced: Bool?
        Task { @MainActor in
            serviced = await ModalGate.runFromRunLoop(activity: activity) {
                MainRunLoopTests.mainQueueIsServicedUnderAModalLoop()
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(serviced, true)
    }

    /// The check and the dialog are one step: nothing can start in between.
    @MainActor
    func testASuppressedDialogNeverOpens() {
        let activity = AppActivity()
        let done = expectation(description: "decided")
        var ran = false
        var asked = 0
        var shown: Void? = ()
        Task { @MainActor in
            shown = await ModalGate.runFromRunLoop(activity: activity, unless: {
                asked += 1
                return true
            }) { ran = true }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertNil(shown)
        XCTAssertFalse(ran)
        XCTAssertEqual(asked, 1)
    }
}
