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
    /// Installs at quit, and whether the next one fails.
    var quitCommits: [StagedUpdate] = []
    var quitCommitFails = false
    var opened: [URL] = []
    var removed: [URL] = []
    var holders: [URL] = []
    var journalDuringStaging: [String] = []

    lazy var coordinator = UpdateCoordinator(environment: environment())

    /// The next launch: a new coordinator, as a new process has, over the same
    /// saved state.
    func relaunch() {
        coordinator = UpdateCoordinator(environment: environment())
    }

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
            commitAtQuit: { [unowned self] update in
                if quitCommitFails { throw UpdateCommit.Refusal.appMoved }
                quitCommits.append(update)
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

    /// A dialog is not work. The USB offer is on screen at most launches with a
    /// USB microphone, and the check after launch answers under it: the update
    /// is offered when the dialog has closed, not put off to the next launch.
    @MainActor
    func testTheSilentOfferWaitsForADialogToClose() async {
        let h = Harness()
        h.presenter.offerChoice = .notNow
        h.activity.begin(.modal)
        let flow = Task { await h.coordinator.checkForUpdates(silent: true) }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(h.presenter.offers.isEmpty, "it opened over the dialog")
        XCTAssertEqual(h.coordinator.phase, .checking, "it gave up until the next launch")

        h.activity.end(.modal)
        await flow.value
        XCTAssertEqual(h.presenter.offers.count, 1)
        XCTAssertEqual(h.coordinator.phase, .idle)
    }

    /// The dialog closed into a take (the name prompt, answered): nothing opens over it.
    @MainActor
    func testTheSilentOfferThatWaitedStaysAwayFromATake() async {
        let h = Harness()
        h.activity.begin(.modal)
        let flow = Task { await h.coordinator.checkForUpdates(silent: true) }
        try? await Task.sleep(for: .milliseconds(100))
        h.recording(true)
        h.activity.end(.modal)
        await flow.value
        XCTAssertTrue(h.presenter.offers.isEmpty)
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

    /// A copy opened beside this one (from the disk image, say) sweeps the
    /// shared journal at launch. The folder this copy downloads into, and then
    /// keeps a staged copy in until the quit, is locked for as long, so that
    /// sweep leaves it. It used to delete it, and the download cut short
    /// counted as a failed install.
    @MainActor
    func testAnotherCopysSweepLeavesTheFolderThisOneIsUsing() async throws {
        let h = Harness()
        var sweptDuringDownload: [URL]?
        h.stager.onStart = { _ in sweptDuringDownload = UpdateSweep.takeLeftovers(store: h.store) }
        await h.coordinator.updateInBackground(promptIfStuck: false)

        XCTAssertEqual(sweptDuringDownload, [], "the other copy's sweep took the folder being downloaded into")
        XCTAssertEqual(h.coordinator.phase, .readyAtQuit)
        XCTAssertEqual(UpdateSweep.takeLeftovers(store: h.store), [], "and the staged copy waiting for the quit")
        XCTAssertEqual(h.store.journal, h.holders.map(\.path))
        let staged = try XCTUnwrap(h.coordinator.stagedForQuit?.staged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
    }

    // MARK: Cloud, behind the recorder

    /// Nothing a guest sees: no window, no dialog, no install while the app
    /// runs. The copy waits for the quit.
    @MainActor
    func testBehindTheRecorderItStagesQuietlyAndWaitsForTheQuit() async {
        let h = Harness()
        await h.coordinator.updateInBackground(promptIfStuck: false)
        XCTAssertEqual(h.coordinator.phase, .readyAtQuit)
        XCTAssertEqual(h.coordinator.stagedForQuit?.version, "9.0.0")
        XCTAssertTrue(h.presenter.offers.isEmpty)
        XCTAssertTrue(h.presenter.windows.isEmpty)
        XCTAssertTrue(h.presenter.confirms.isEmpty)
        XCTAssertTrue(h.commits.isEmpty, "it installed while the app was open")
        XCTAssertEqual(h.store.journal, h.holders.map(\.path), "the staged copy is swept if the app dies")
        XCTAssertNotNil(h.coordinator.lastCheck)

        XCTAssertTrue(h.coordinator.installAtQuit())
        XCTAssertEqual(h.quitCommits.map(\.version), ["9.0.0"])
        XCTAssertEqual(h.store.journal, [], "probation owns the previous version now")
        XCTAssertNil(h.coordinator.stagedForQuit)
        XCTAssertTrue(h.removed.isEmpty)
    }

    @MainActor
    func testNothingStagedNothingInstalledAtQuit() {
        let h = Harness()
        XCTAssertFalse(h.coordinator.installAtQuit())
        XCTAssertTrue(h.quitCommits.isEmpty)
    }

    /// The install at quit refused (the app was moved meanwhile): the copy goes,
    /// and the app quits as it was.
    @MainActor
    func testAnInstallAtQuitThatFailsLeavesNothingBehind() async {
        let h = Harness()
        await h.coordinator.updateInBackground(promptIfStuck: false)
        h.quitCommitFails = true
        XCTAssertFalse(h.coordinator.installAtQuit())
        XCTAssertEqual(h.removed, [h.holders[0]])
        XCTAssertEqual(h.store.journal, [])
        XCTAssertEqual(h.coordinator.phase, .idle)
    }

    /// It waits for a take to be over before it downloads anything, as long as
    /// that takes, and a take that starts meanwhile stops it.
    @MainActor
    func testBehindTheRecorderItWaitsForATake() async {
        let h = Harness()
        h.recording(true)
        let flow = Task { await h.coordinator.updateInBackground(promptIfStuck: false) }
        await waitUntil { h.coordinator.phase == .waiting }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(h.stager.starts, 0)
        h.recording(false)
        await flow.value
        XCTAssertEqual(h.coordinator.phase, .readyAtQuit)
        XCTAssertTrue(h.presenter.windows.isEmpty)
    }

    @MainActor
    func testBehindTheRecorderATakeThatStartsStopsTheDownload() async {
        let h = Harness()
        h.stager.duration = .seconds(2)
        h.stager.onStart = { start in
            if start == 1 {
                MainRunLoop.perform(after: 0.05) { h.recording(true) }
            } else {
                h.stager.duration = .milliseconds(20)
            }
        }
        let flow = Task { await h.coordinator.updateInBackground(promptIfStuck: false) }
        await waitUntil { h.stager.cancellations == 1 }
        h.recording(false)
        await flow.value
        XCTAssertEqual(h.stager.starts, 2)
        XCTAssertEqual(h.coordinator.phase, .readyAtQuit)
    }

    /// A failure says nothing; one that would repeat counts towards the rest,
    /// and a dropped connection does not.
    @MainActor
    func testBehindTheRecorderAFailureIsSilent() async {
        let h = Harness()
        h.stager.failure = URLError(.networkConnectionLost)
        await h.coordinator.updateInBackground(promptIfStuck: false)
        h.stager.failure = SelfUpdater.Failure.diskImage
        await h.coordinator.updateInBackground(promptIfStuck: false)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(h.presenter.failures.isEmpty)
        XCTAssertTrue(h.presenter.offers.isEmpty)
        XCTAssertEqual(h.store.load().failures["9.0.0"]?.count, 1)
        XCTAssertEqual(h.coordinator.phase, .idle)
    }

    /// A copy that cannot replace itself: the check after launch still offers
    /// the download, as before; a check while idle says nothing.
    @MainActor
    func testACopyThatCannotReplaceItselfIsOfferedOnlyAfterLaunch() async {
        let h = Harness()
        h.obstacle = .notWritable
        h.presenter.offerChoice = .notNow
        await h.coordinator.updateInBackground(promptIfStuck: false)
        XCTAssertTrue(h.presenter.offers.isEmpty)
        await h.coordinator.updateInBackground(promptIfStuck: true)
        XCTAssertEqual(h.presenter.offers.map(\.canInstall), [false])
        XCTAssertEqual(h.stager.starts, 0)
        XCTAssertEqual(h.coordinator.phase, .idle)
    }

    /// Automatic installs resting after two real failures: after launch the
    /// prompt offers it, as before; while idle nothing happens.
    @MainActor
    func testARestingVersionIsOfferedOnlyAfterLaunch() async {
        let h = Harness()
        let now = Date()
        UpdateRollback.recordFailure(of: "9.0.0", store: h.store, now: now)
        UpdateRollback.recordFailure(of: "9.0.0", store: h.store, now: now)
        h.presenter.offerChoice = .notNow
        await h.coordinator.updateInBackground(promptIfStuck: false)
        XCTAssertTrue(h.presenter.offers.isEmpty)
        XCTAssertEqual(h.stager.starts, 0)
        await h.coordinator.updateInBackground(promptIfStuck: true)
        XCTAssertEqual(h.presenter.offers.map(\.canInstall), [true])
    }

    @MainActor
    func testAVersionAlreadyHeldIsNotFetchedAgain() async {
        let h = Harness()
        await h.coordinator.updateInBackground(promptIfStuck: false)
        await h.coordinator.updateInBackground(promptIfStuck: false)
        XCTAssertEqual(h.stager.starts, 1)
        XCTAssertEqual(h.coordinator.phase, .readyAtQuit)
    }

    /// A newer version out while an older one waits: the older copy goes.
    @MainActor
    func testANewerVersionReplacesTheOneHeld() async {
        let h = Harness()
        await h.coordinator.updateInBackground(promptIfStuck: false)
        h.result = .available(version: "9.1.0", downloadURL: URL(string: "https://downloads.test/u.dmg")!,
                              releaseURL: URL(string: "https://downloads.test/notes")!)
        await h.coordinator.updateInBackground(promptIfStuck: false)
        XCTAssertEqual(h.stager.starts, 2)
        XCTAssertEqual(h.removed, [h.holders[0]])
        XCTAssertEqual(h.coordinator.stagedForQuit?.version, "9.1.0")
    }

    @MainActor
    func testAVersionThisCopyRolledBackFromIsNotFetched() async {
        let h = Harness()
        var state = UpdateState()
        state.skipped = "9.0.0cr"
        h.store.save(state)
        await h.coordinator.updateInBackground(promptIfStuck: true)
        XCTAssertEqual(h.stager.starts, 0)
        XCTAssertTrue(h.presenter.offers.isEmpty)
    }

    /// Check for Updates… with a copy waiting for the quit: install it now, or
    /// keep it for the quit.
    @MainActor
    func testTheMenuWithACopyHeldOffersToInstallItNow() async {
        let h = Harness()
        await h.coordinator.updateInBackground(promptIfStuck: false)
        h.presenter.confirmAnswer = false
        await h.coordinator.checkForUpdates(silent: false)
        XCTAssertEqual(h.presenter.confirms, ["9.0.0"])
        XCTAssertTrue(h.commits.isEmpty)
        XCTAssertEqual(h.coordinator.phase, .readyAtQuit, "Not Now threw the copy away")
        XCTAssertTrue(h.removed.isEmpty)

        h.presenter.confirmAnswer = true
        await h.coordinator.checkForUpdates(silent: false)
        XCTAssertEqual(h.commits.map(\.version), ["9.0.0"])
        XCTAssertEqual(h.coordinator.phase, .relaunching)
    }

    /// The silent check after launch leaves a held copy alone.
    @MainActor
    func testTheSilentCheckLeavesAHeldCopyAlone() async {
        let h = Harness()
        await h.coordinator.updateInBackground(promptIfStuck: false)
        await h.coordinator.checkForUpdates(silent: true)
        XCTAssertTrue(h.presenter.confirms.isEmpty)
        XCTAssertEqual(h.coordinator.phase, .readyAtQuit)
    }

    /// Asked for while the quiet flow downloads: the quiet one gives way.
    @MainActor
    func testTheMenuDuringTheQuietDownloadTakesOver() async {
        let h = Harness()
        h.stager.duration = .seconds(5)
        XCTAssertTrue(h.coordinator.startBackgroundUpdate(promptIfStuck: false))
        XCTAssertFalse(h.coordinator.startBackgroundUpdate(promptIfStuck: false), "two quiet flows at once")
        await waitUntil { h.coordinator.phase == .downloading }
        h.stager.duration = .milliseconds(20)
        h.presenter.offerChoice = .notNow
        await h.coordinator.checkForUpdates(silent: false)
        XCTAssertEqual(h.stager.cancellations, 1)
        XCTAssertEqual(h.presenter.offers.count, 1)
        XCTAssertEqual(h.coordinator.phase, .idle)
    }

    /// A quit during the quiet download stops it, as for any download.
    @MainActor
    func testAQuitDuringTheQuietDownloadWaitsForItToStop() async {
        let h = Harness()
        h.stager.duration = .seconds(5)
        h.coordinator.startBackgroundUpdate(promptIfStuck: false)
        await waitUntil { h.coordinator.phase == .downloading }
        var replied = false
        XCTAssertTrue(h.coordinator.cancelBeforeQuit(limit: 3) { replied = true })
        await waitUntil { replied }
        XCTAssertEqual(h.stager.cancellations, 1)
        XCTAssertFalse(h.coordinator.installAtQuit())
    }

    func testChecksWhileOpenAreDueEveryFewHoursAndSoonAfterAWake() {
        let now = Date()
        XCTAssertTrue(BackgroundUpdateSchedule.isDue(now: now, lastCheck: nil, afterWake: false))
        XCTAssertFalse(BackgroundUpdateSchedule.isDue(now: now, lastCheck: now.addingTimeInterval(-3 * 3600),
                                                      afterWake: false))
        XCTAssertTrue(BackgroundUpdateSchedule.isDue(now: now, lastCheck: now.addingTimeInterval(-4 * 3600),
                                                     afterWake: false))
        XCTAssertFalse(BackgroundUpdateSchedule.isDue(now: now, lastCheck: now.addingTimeInterval(-30 * 60),
                                                      afterWake: true))
        XCTAssertTrue(BackgroundUpdateSchedule.isDue(now: now, lastCheck: now.addingTimeInterval(-61 * 60),
                                                     afterWake: true))
    }

    /// The launch check counts as a check; one that failed does not.
    @MainActor
    func testOnlyAnAnsweredCheckCounts() async {
        let h = Harness()
        h.result = .error("offline")
        await h.coordinator.checkForUpdates(silent: true)
        XCTAssertNil(h.coordinator.lastCheck)
        h.result = .upToDate(version: "9.0.0")
        _ = await h.coordinator.runAtLaunch(window: FakeProgress(), checkTimeout: .seconds(2), budget: .seconds(5))
        XCTAssertNotNil(h.coordinator.lastCheck)
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
            h.relaunch()
        }
        XCTAssertEqual(h.stager.starts, UpdateRollback.maximumFailures)
        let outcome = await launch(h)
        XCTAssertEqual(outcome, .openRecorder(checkAfterLaunch: true))
        XCTAssertEqual(h.stager.starts, UpdateRollback.maximumFailures)
    }

    /// A connection that stalled or dropped says nothing about the next launch.
    /// Two launches on bad Wi-Fi used to rest the automatic install for a day,
    /// leaving the guest the prompt, which needs a click.
    @MainActor
    func testAtLaunchNetworkFailuresDoNotRestTheAutomaticInstall() async {
        let h = Harness()
        for failure in [URLError(.timedOut), URLError(.networkConnectionLost), URLError(.notConnectedToInternet)] {
            h.stager.failure = failure
            let outcome = await launch(h)
            XCTAssertEqual(outcome, .openRecorder(checkAfterLaunch: true))
        }
        XCTAssertTrue(h.store.load().failures.isEmpty)
        XCTAssertTrue(UpdateRollback.shouldInstallAutomatically("9.0.0", store: h.store))

        // The network is back: the next launch installs.
        h.stager.failure = nil
        let outcome = await launch(h)
        XCTAssertEqual(outcome, .relaunching)
        XCTAssertEqual(h.stager.starts, 4)
    }

    /// A network failure does not wipe out what a real one recorded.
    @MainActor
    func testAtLaunchAFailureThatWouldRepeatStillCounts() async {
        let h = Harness()
        h.stager.failure = SelfUpdater.Failure.noSpace
        _ = await launch(h)
        h.relaunch()
        h.stager.failure = URLError(.timedOut)
        _ = await launch(h)
        h.relaunch()
        h.stager.failure = UpdateFailure.selfTest
        _ = await launch(h)
        XCTAssertEqual(h.store.load().failures["9.0.0"]?.count, 2)
        XCTAssertFalse(UpdateRollback.shouldInstallAutomatically("9.0.0", store: h.store))
    }

    /// A failed install at launch is followed at once by the check after
    /// launch, which tries again behind the recorder. One launch counts the
    /// version once: until it did, a download that got the version before (the
    /// link serves it for a minute after a release) failed twice in one launch,
    /// rested the automatic install for a day, and showed guests a prompt.
    @MainActor
    func testAtLaunchOneLaunchCountsAFailureOnce() async {
        let h = Harness()
        h.stager.failure = SelfUpdater.Failure.notNewer
        let outcome = await launch(h)
        XCTAssertEqual(outcome, .openRecorder(checkAfterLaunch: true))
        await h.coordinator.updateInBackground(promptIfStuck: true)
        XCTAssertEqual(h.stager.starts, 2)
        XCTAssertEqual(h.store.load().failures["9.0.0"]?.count, 1)
        XCTAssertTrue(UpdateRollback.shouldInstallAutomatically("9.0.0", store: h.store))
        XCTAssertTrue(h.presenter.offers.isEmpty)

        // The link serves the new version now: the next launch installs.
        h.relaunch()
        h.stager.failure = nil
        let next = await launch(h)
        XCTAssertEqual(next, .relaunching)
    }

    /// Counted once per launch, a failure that keeps coming back still rests
    /// the automatic install after two launches.
    @MainActor
    func testAFailureThatKeepsComingBackStillRestsAfterTwoLaunches() async {
        let h = Harness()
        h.stager.failure = SelfUpdater.Failure.notNewer
        for _ in 1...UpdateRollback.maximumFailures {
            _ = await launch(h)
            await h.coordinator.updateInBackground(promptIfStuck: true)
            h.relaunch()
        }
        XCTAssertEqual(h.store.load().failures["9.0.0"]?.count, UpdateRollback.maximumFailures)
        XCTAssertFalse(UpdateRollback.shouldInstallAutomatically("9.0.0", store: h.store))
    }

    func testWhichFailuresMayPassByThemselves() {
        XCTAssertTrue(UpdateCoordinator.mayPassByItself(URLError(.timedOut)))
        XCTAssertTrue(UpdateCoordinator.mayPassByItself(URLError(.cannotFindHost)))
        XCTAssertTrue(UpdateCoordinator.mayPassByItself(UpdateFailure.busy))
        // The download server's own trouble, not this Mac's.
        XCTAssertTrue(UpdateCoordinator.mayPassByItself(SelfUpdater.Failure.http(500)))
        XCTAssertTrue(UpdateCoordinator.mayPassByItself(SelfUpdater.Failure.http(503)))
        for failure in [SelfUpdater.Failure.diskImage, .copy, .untrusted, .noSpace, .timedOut, .http(404),
                        .notNewer, .wrongArchitecture, .swap("EACCES")] {
            XCTAssertFalse(UpdateCoordinator.mayPassByItself(failure), "\(failure)")
        }
        XCTAssertFalse(UpdateCoordinator.mayPassByItself(UpdateFailure.selfTest))
        XCTAssertFalse(UpdateCoordinator.mayPassByItself(UpdateCommit.Refusal.appMoved))
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
