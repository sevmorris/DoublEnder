import XCTest
@testable import DoublEnder

// MARK: - Fakes

@MainActor
private final class FakeProgress: UpdateProgressShowing {
    var messages: [String] = []
    var forwards = 0
    var closed = false
    let onButton: () -> Void

    init(onButton: @escaping () -> Void = {}) {
        self.onButton = onButton
    }

    func showProgress(_ message: String, fraction: Double?) { messages.append(message) }
    func bringForward() { forwards += 1 }
    func close() { closed = true }
}

@MainActor
private final class FakePresenter: UpdatePresenting {
    var offerChoice: UpdateOfferChoice = .install
    var confirmAnswer = true
    var failureAnswer = false
    var offers: [UpdateOffer] = []
    var confirms: [String] = []
    var failures: [String] = []
    var informs: [String] = []
    var windows: [FakeProgress] = []
    var onConfirm: (() -> Void)?

    func offer(_ offer: UpdateOffer) -> UpdateOfferChoice {
        offers.append(offer)
        return offerChoice
    }

    func confirmRelaunch(appName: String, version: String) -> Bool {
        confirms.append(version)
        onConfirm?()
        return confirmAnswer
    }

    func failure(appName: String, message: String) -> Bool {
        failures.append(message)
        return failureAnswer
    }

    func inform(title: String, text: String) { informs.append(title) }

    func makeProgress(title: String, buttonTitle: String, onButton: @escaping () -> Void) -> UpdateProgressShowing {
        let window = FakeProgress(onButton: onButton)
        windows.append(window)
        return window
    }
}

/// Stands in for the download, the disk image and the copy: it takes
/// `duration`, honours cancellation, and leaves a folder where the copy goes.
@MainActor
private final class FakeStager {
    var duration: Duration = .milliseconds(50)
    var failure: Error?
    var onStart: ((Int) -> Void)?
    var beforeReturn: (() -> Void)?
    private(set) var starts = 0
    private(set) var cancellations = 0

    func stage(_ download: URL, _ holder: URL, _ mode: UpdateCoordinator.Mode,
               _ progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        starts += 1
        onStart?(starts)
        progress(0.5)
        do {
            try await Task.sleep(for: duration)
        } catch {
            cancellations += 1
            throw error
        }
        progress(1)
        beforeReturn?()
        if let failure { throw failure }
        let staged = holder.appendingPathComponent("Installed.app", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        return staged
    }
}

@MainActor
private final class Harness {
    let folder: URL
    let store: UpdateStateStore
    let activity = AppActivity()
    let presenter = FakePresenter()
    let stager = FakeStager()
    var result: UpdateChecker.Result = .available(version: "9.0.0",
                                                  downloadURL: URL(string: "https://downloads.test/u.dmg")!,
                                                  releaseURL: URL(string: "https://downloads.test/notes")!)
    var obstacle: SelfUpdater.Obstacle?
    var onObstacle: (() -> Void)?
    var checkDelay: Duration = .zero
    /// Installs that went ahead, and what was in progress at the time.
    var commits: [StagedUpdate] = []
    var blockersAtCommit: [Set<AppActivity.Blocker>] = []
    var opened: [URL] = []
    var removed: [URL] = []
    var holders: [URL] = []
    var journalDuringStaging: [String] = []

    lazy var coordinator = UpdateCoordinator(environment: environment())

    init() {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = UpdateStateStore(url: folder.appendingPathComponent("state/update-state.json"))
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    var installed: URL { folder.appendingPathComponent("Installed.app") }

    func environment() -> UpdateCoordinator.Environment {
        UpdateCoordinator.Environment(
            appName: "DoublEnder",
            busyMessage: "Waiting for the recording.",
            showsReleaseNotes: true,
            installedURL: installed,
            check: { [unowned self] in
                if checkDelay > .zero { try? await Task.sleep(for: checkDelay) }
                return result
            },
            obstacle: { [unowned self] in
                onObstacle?()
                return obstacle
            },
            makeHolder: { [unowned self] in
                let holder = folder.appendingPathComponent("holder-\(holders.count)", isDirectory: true)
                try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
                holders.append(holder)
                return holder
            },
            stage: { [unowned self] download, holder, mode, progress in
                journalDuringStaging = store.journal
                return try await stager.stage(download, holder, mode, progress)
            },
            commit: { [unowned self] update in
                // As UpdateCommit does: its own check comes first.
                if activity.blocksRelaunch { throw UpdateCommit.Refusal.busy }
                blockersAtCommit.append(activity.blockers)
                commits.append(update)
            },
            removeFolder: { [unowned self] in
                removed.append($0)
                try? FileManager.default.removeItem(at: $0)
            },
            activity: activity,
            presenter: presenter,
            store: store,
            openURL: { [unowned self] in opened.append($0) },
            pollInterval: .milliseconds(10))
    }

    func recording(_ on: Bool) {
        activity.recorder = on ? { [.recording] } : { [] }
    }
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 5,
                       file: StaticString = #filePath, line: UInt = #line) async {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end {
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), "timed out waiting", file: file, line: line)
}

// MARK: - Tests

final class UpdateCoordinatorTests: XCTestCase {

    // MARK: The check

    @MainActor
    func testUpToDateIsToldOnlyWhenAsked() async {
        let h = Harness()
        h.result = .upToDate(version: "1.0.0")
        await h.coordinator.checkForUpdates(silent: true)
        XCTAssertTrue(h.presenter.informs.isEmpty)
        await h.coordinator.checkForUpdates(silent: false)
        XCTAssertEqual(h.presenter.informs, ["You're up to date"])
        XCTAssertEqual(h.coordinator.phase, .idle)
    }

    @MainActor
    func testAnUpdateOnHoldIsToldOnlyWhenAsked() async {
        let h = Harness()
        h.result = .onHold(version: "9.0.0")
        await h.coordinator.checkForUpdates(silent: true)
        XCTAssertTrue(h.presenter.informs.isEmpty)
        XCTAssertTrue(h.presenter.offers.isEmpty)
        await h.coordinator.checkForUpdates(silent: false)
        XCTAssertEqual(h.presenter.informs, ["DoublEnder 9.0.0 is on hold"])
        XCTAssertEqual(h.stager.starts, 0)
    }

    @MainActor
    func testAnUpdateDownloadsStagesAndInstalls() async {
        let h = Harness()
        await h.coordinator.checkForUpdates(silent: false)

        XCTAssertEqual(h.presenter.offers.count, 1)
        XCTAssertEqual(h.commits.count, 1)
        XCTAssertEqual(h.commits.first?.staged, h.holders.first?.appendingPathComponent("Installed.app", isDirectory: true))
        XCTAssertEqual(h.commits.first?.installed, h.installed)
        XCTAssertEqual(h.blockersAtCommit, [[]])
        // Nothing had to wait, so it did not ask again.
        XCTAssertTrue(h.presenter.confirms.isEmpty)
        XCTAssertEqual(h.coordinator.phase, .relaunching)
        // The folder was on the journal while it was in use, and probation owns it now.
        XCTAssertEqual(h.journalDuringStaging, h.holders.map(\.path))
        XCTAssertEqual(h.store.journal, [])
        XCTAssertEqual(h.presenter.windows.count, 1)
        XCTAssertTrue(h.presenter.windows[0].closed)
    }

    @MainActor
    func testACopyThatCannotReplaceItselfOffersTheDownload() async {
        let h = Harness()
        h.obstacle = .readOnlyLocation
        h.presenter.offerChoice = .download
        await h.coordinator.checkForUpdates(silent: false)
        XCTAssertEqual(h.presenter.offers.first?.canInstall, false)
        XCTAssertEqual(h.opened, [URL(string: "https://downloads.test/u.dmg")!])
        XCTAssertEqual(h.stager.starts, 0)
    }

    @MainActor
    func testReleaseNotesOpenTheNotes() async {
        let h = Harness()
        h.presenter.offerChoice = .releaseNotes
        await h.coordinator.checkForUpdates(silent: false)
        XCTAssertEqual(h.opened, [URL(string: "https://downloads.test/notes")!])
        XCTAssertEqual(h.coordinator.phase, .idle)
    }

    /// RECORD pressed while the copy was being checked: the check after launch
    /// opens no prompt over the take.
    @MainActor
    func testATakeThatStartsDuringTheCheckKeepsTheSilentOfferAway() async {
        let h = Harness()
        h.onObstacle = { h.recording(true) }
        await h.coordinator.checkForUpdates(silent: true)
        XCTAssertTrue(h.presenter.offers.isEmpty)
        XCTAssertEqual(h.stager.starts, 0)
        XCTAssertEqual(h.coordinator.phase, .idle)
    }

    @MainActor
    func testTheSilentCheckDoesNotOfferAVersionThisCopyRolledBackFrom() async {
        let h = Harness()
        var state = UpdateState()
        state.skipped = "9.0.0lr"
        h.store.save(state)
        await h.coordinator.checkForUpdates(silent: true)
        XCTAssertTrue(h.presenter.offers.isEmpty)
        // Asked for, it is offered.
        h.presenter.offerChoice = .notNow
        await h.coordinator.checkForUpdates(silent: false)
        XCTAssertEqual(h.presenter.offers.count, 1)
    }

    // MARK: Work in progress comes first

    /// Accepted from the menu during a take: nothing is downloaded until the
    /// take is over, and then it asks before it relaunches.
    @MainActor
    func testAnUpdateAskedForDuringATakeWaitsToDownload() async {
        let h = Harness()
        h.recording(true)
        let flow = Task { await h.coordinator.checkForUpdates(silent: false) }
        await waitUntil { h.coordinator.phase == .waiting }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(h.stager.starts, 0)
        XCTAssertEqual(h.presenter.windows.first?.messages.last, "Waiting for the recording.")

        h.recording(false)
        await flow.value
        XCTAssertEqual(h.stager.starts, 1)
        XCTAssertEqual(h.presenter.confirms, ["9.0.0"])
        XCTAssertEqual(h.commits.count, 1)
        XCTAssertEqual(h.blockersAtCommit, [[]])
    }

    /// A take that starts during the download stops it, and it starts again
    /// once the take is over.
    @MainActor
    func testATakeThatStartsDuringTheDownloadStopsItUntilTheTakeIsOver() async {
        let h = Harness()
        h.stager.duration = .seconds(2)
        h.stager.onStart = { start in
            if start == 1 {
                MainRunLoop.perform(after: 0.05) { h.recording(true) }
            } else {
                h.stager.duration = .milliseconds(20)
            }
        }
        let flow = Task { await h.coordinator.checkForUpdates(silent: false) }
        await waitUntil { h.stager.cancellations == 1 }
        await waitUntil { h.coordinator.phase == .waiting }
        XCTAssertEqual(h.removed, [h.holders[0]], "the stopped copy's folder went")

        h.recording(false)
        await flow.value
        XCTAssertEqual(h.stager.starts, 2)
        XCTAssertEqual(h.commits.count, 1)
        XCTAssertEqual(h.presenter.confirms.count, 1)
    }

    /// A dialog is not work: it does not stop a download, but the install waits
    /// for it to close, then asks.
    @MainActor
    func testAnInstallWaitsForADialogAndThenAsks() async {
        let h = Harness()
        h.stager.beforeReturn = { h.activity.begin(.modal) }
        let flow = Task { await h.coordinator.checkForUpdates(silent: false) }
        await waitUntil { h.coordinator.phase == .waiting }
        XCTAssertEqual(h.stager.cancellations, 0)
        XCTAssertTrue(h.commits.isEmpty)

        h.activity.end(.modal)
        await flow.value
        XCTAssertEqual(h.presenter.confirms.count, 1)
        XCTAssertEqual(h.commits.count, 1)
    }

    @MainActor
    func testNotNowAfterWaitingDiscardsTheStagedCopy() async {
        let h = Harness()
        h.presenter.confirmAnswer = false
        h.stager.beforeReturn = { h.activity.begin(.modal) }
        let flow = Task { await h.coordinator.checkForUpdates(silent: false) }
        await waitUntil { h.coordinator.phase == .waiting }
        h.activity.end(.modal)
        await flow.value
        XCTAssertTrue(h.commits.isEmpty)
        XCTAssertEqual(h.removed, [h.holders[0]])
        XCTAssertEqual(h.store.journal, [])
        XCTAssertEqual(h.coordinator.phase, .idle)
    }

    /// Something that starts while the question is up (a queued stop moving to
    /// an upload, say) is caught by the install's own check, and the update
    /// waits again, then asks again.
    @MainActor
    func testWorkThatStartsDuringTheQuestionStopsTheInstall() async {
        let h = Harness()
        h.stager.beforeReturn = { h.activity.begin(.modal) }
        var asked = 0
        h.presenter.onConfirm = {
            asked += 1
            if asked == 1 {
                h.activity.recorder = { [.uploading] }
                MainRunLoop.perform(after: 0.1) { h.activity.recorder = { [] } }
            }
        }
        let flow = Task { await h.coordinator.checkForUpdates(silent: false) }
        await waitUntil { h.coordinator.phase == .waiting }
        h.activity.end(.modal)
        await flow.value
        XCTAssertEqual(h.presenter.confirms.count, 2)
        XCTAssertEqual(h.commits.count, 1)
        XCTAssertEqual(h.blockersAtCommit, [[]], "it installed only with nothing under way")
    }

    // MARK: One flow at a time

    @MainActor
    func testAskingAgainBringsTheWindowForwardInsteadOfASecondDownload() async {
        let h = Harness()
        h.stager.duration = .milliseconds(300)
        let flow = Task { await h.coordinator.checkForUpdates(silent: false) }
        await waitUntil { h.coordinator.phase == .downloading }
        await h.coordinator.checkForUpdates(silent: false)
        await h.coordinator.checkForUpdates(silent: true)
        XCTAssertEqual(h.presenter.offers.count, 1)
        XCTAssertEqual(h.presenter.windows.first?.forwards, 2)
        await flow.value
        XCTAssertEqual(h.stager.starts, 1)
        XCTAssertEqual(h.commits.count, 1)
    }

    // MARK: Failures and Cancel

    /// The download fails as a take begins: nothing opens over the take, and
    /// the failure is told once the take is over, once.
    @MainActor
    func testAFailureDuringATakeIsToldAfterIt() async {
        let h = Harness()
        h.stager.failure = URLError(.networkConnectionLost)
        h.stager.beforeReturn = { h.recording(true) }
        await h.coordinator.checkForUpdates(silent: false)
        XCTAssertEqual(h.coordinator.phase, .idle)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(h.presenter.failures.isEmpty)

        h.recording(false)
        await waitUntil { h.presenter.failures.count == 1 }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(h.presenter.failures.count, 1)
        XCTAssertTrue(h.commits.isEmpty)
        XCTAssertEqual(h.removed, [h.holders[0]])
    }

    @MainActor
    func testDownloadOnAFailureOpensTheDMG() async {
        let h = Harness()
        h.stager.failure = SelfUpdater.Failure.untrusted
        h.presenter.failureAnswer = true
        await h.coordinator.checkForUpdates(silent: false)
        await waitUntil { h.opened == [URL(string: "https://downloads.test/u.dmg")!] }
    }

    /// A newer attempt makes an older failure not worth telling.
    @MainActor
    func testAFailureNotYetToldIsDroppedByANewCheck() async {
        let h = Harness()
        h.stager.failure = URLError(.timedOut)
        h.stager.beforeReturn = { h.recording(true) }
        await h.coordinator.checkForUpdates(silent: false)
        h.result = .upToDate(version: "9.0.0")
        h.recording(false)
        await h.coordinator.checkForUpdates(silent: true)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(h.presenter.failures.isEmpty)
    }

    @MainActor
    func testCancelStopsTheDownloadAndSaysNothing() async {
        let h = Harness()
        h.stager.duration = .seconds(5)
        let flow = Task { await h.coordinator.checkForUpdates(silent: false) }
        await waitUntil { h.coordinator.phase == .downloading }
        let started = Date()
        h.presenter.windows[0].onButton()
        await flow.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(h.stager.cancellations, 1)
        XCTAssertTrue(h.commits.isEmpty)
        XCTAssertEqual(h.removed, [h.holders[0]])
        XCTAssertEqual(h.store.journal, [])
        XCTAssertEqual(h.coordinator.phase, .idle)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(h.presenter.failures.isEmpty)
    }

    // MARK: Quitting

    @MainActor
    func testAQuitDuringTheDownloadWaitsForItToStop() async {
        let h = Harness()
        h.stager.duration = .seconds(5)
        let flow = Task { await h.coordinator.checkForUpdates(silent: false) }
        await waitUntil { h.coordinator.phase == .downloading }
        var replied = false
        let started = Date()
        XCTAssertTrue(h.coordinator.cancelBeforeQuit(limit: 3) { replied = true })
        await waitUntil { replied }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "it replied when the work stopped, not at the limit")
        XCTAssertEqual(h.stager.cancellations, 1)
        await flow.value
        XCTAssertEqual(h.removed, [h.holders[0]])
    }

    @MainActor
    func testAQuitWithNoDownloadDoesNotWait() {
        let h = Harness()
        XCTAssertFalse(h.coordinator.cancelBeforeQuit { XCTFail("nothing to wait for") })
    }

    @MainActor
    func testAQuitWhileWaitingTakesTheStagedCopyWithIt() async {
        let h = Harness()
        h.stager.beforeReturn = { h.activity.begin(.modal) }
        let flow = Task { await h.coordinator.checkForUpdates(silent: false) }
        await waitUntil { h.coordinator.phase == .waiting }
        h.coordinator.cleanUpForQuit()
        XCTAssertEqual(h.removed, [h.holders[0]])
        XCTAssertEqual(h.store.journal, [])
        h.coordinator.cancel()
        await flow.value
        XCTAssertTrue(h.commits.isEmpty)
    }

    // MARK: Cloud, at launch

    @MainActor
    private func launch(_ h: Harness, window: FakeProgress? = nil, checkTimeout: Duration = .seconds(2),
                        budget: Duration = .seconds(5)) async -> UpdateCoordinator.LaunchOutcome {
        await h.coordinator.runAtLaunch(window: window ?? FakeProgress(), checkTimeout: checkTimeout, budget: budget)
    }

    @MainActor
    func testAtLaunchItInstallsWithoutAsking() async {
        let h = Harness()
        let outcome = await launch(h)
        XCTAssertEqual(outcome, .relaunching)
        XCTAssertTrue(h.presenter.offers.isEmpty)
        XCTAssertTrue(h.presenter.confirms.isEmpty)
        XCTAssertEqual(h.commits.count, 1)
    }

    @MainActor
    func testAtLaunchUpToDateOpensTheRecorderQuietly() async {
        let h = Harness()
        h.result = .upToDate(version: "9.0.0")
        let outcome = await launch(h)
        XCTAssertEqual(outcome, .openRecorder(checkAfterLaunch: false))
        XCTAssertEqual(h.coordinator.phase, .idle)
    }

    @MainActor
    func testAtLaunchASlowCheckOpensTheRecorder() async {
        let h = Harness()
        h.checkDelay = .seconds(2)
        let started = Date()
        let outcome = await launch(h, checkTimeout: .milliseconds(100))
        XCTAssertEqual(outcome, .openRecorder(checkAfterLaunch: true))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    @MainActor
    func testAtLaunchAVersionThisCopyRolledBackFromIsNotInstalled() async {
        let h = Harness()
        var state = UpdateState()
        state.skipped = "9.0.0cr"
        h.store.save(state)
        let outcome = await launch(h)
        XCTAssertEqual(outcome, .openRecorder(checkAfterLaunch: false))
        XCTAssertEqual(h.stager.starts, 0)
    }

    @MainActor
    func testAtLaunchACopyThatCannotReplaceItselfLeavesItToThePrompt() async {
        let h = Harness()
        h.obstacle = .notWritable
        let outcome = await launch(h)
        XCTAssertEqual(outcome, .openRecorder(checkAfterLaunch: true))
        XCTAssertEqual(h.stager.starts, 0)
    }

    @MainActor
    func testAtLaunchTheInstallGivesUpAtItsBudget() async {
        let h = Harness()
        h.stager.duration = .seconds(5)
        let started = Date()
        let outcome = await launch(h, budget: .milliseconds(150))
        XCTAssertEqual(outcome, .openRecorder(checkAfterLaunch: true))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(h.stager.cancellations, 1)
        XCTAssertTrue(h.commits.isEmpty)
    }

    /// Two failures at launch, and the next launch does not try again for a
    /// day: a guest should not pay for a doomed download every time.
    @MainActor
    func testAtLaunchRepeatedFailuresRest() async {
        let h = Harness()
        h.stager.failure = SelfUpdater.Failure.diskImage
        for _ in 1...UpdateRollback.maximumFailures {
            let outcome = await launch(h)
            XCTAssertEqual(outcome, .openRecorder(checkAfterLaunch: true))
        }
        XCTAssertEqual(h.stager.starts, UpdateRollback.maximumFailures)
        let outcome = await launch(h)
        XCTAssertEqual(outcome, .openRecorder(checkAfterLaunch: true))
        XCTAssertEqual(h.stager.starts, UpdateRollback.maximumFailures)
    }

    @MainActor
    func testAtLaunchSkipStopsTheDownload() async {
        let h = Harness()
        h.stager.duration = .seconds(5)
        let flow = Task { await launch(h) }
        await waitUntil { h.coordinator.phase == .downloading }
        h.coordinator.cancel()
        let outcome = await flow.value
        XCTAssertEqual(outcome, .openRecorder(checkAfterLaunch: false))
        XCTAssertEqual(h.stager.cancellations, 1)
        XCTAssertTrue(h.commits.isEmpty)
    }

    /// Check for Updates… during the launch install brings its window forward
    /// rather than starting a second download beside it.
    @MainActor
    func testTheMenuDuringTheLaunchInstallBringsItsWindowForward() async {
        let h = Harness()
        h.stager.duration = .milliseconds(300)
        let window = FakeProgress()
        let flow = Task { await launch(h, window: window) }
        await waitUntil { h.coordinator.phase == .downloading }
        await h.coordinator.checkForUpdates(silent: false)
        XCTAssertEqual(window.forwards, 1)
        XCTAssertTrue(h.presenter.offers.isEmpty)
        _ = await flow.value
        XCTAssertEqual(h.stager.starts, 1)
    }

    @MainActor
    func testAtLaunchItNeverWaitsForWork() async {
        let h = Harness()
        h.activity.begin(.modal)
        h.stager.beforeReturn = { h.recording(true) }
        let outcome = await launch(h)
        XCTAssertEqual(outcome, .openRecorder(checkAfterLaunch: true))
        XCTAssertTrue(h.commits.isEmpty)
        XCTAssertEqual(h.removed.count, 1)
    }
}
