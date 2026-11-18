import XCTest
@testable import DoublEnder

/// The order of the install's steps is what keeps the installed app whole, so
/// each test records the steps and checks the order and what is undone.
final class UpdateCommitTests: XCTestCase {

    private enum Boom: Error { case swap, relaunch }

    private final class Recorder {
        var steps: [String] = []
        var blocked = false
        var vetted = true
        var sameApp = true
        var relaunchFails = false
        var swapFails = false
        var armFails = false
    }

    private let update = StagedUpdate(version: "2.9.0", staged: URL(fileURLWithPath: "/tmp/holder/App.app"),
                                      installed: URL(fileURLWithPath: "/Applications/App.app"))

    private func commit(_ r: Recorder) -> UpdateCommit {
        UpdateCommit(
            isBlocked: { r.steps.append("isBlocked"); return r.blocked },
            beginCommitting: { r.steps.append("begin") },
            endCommitting: { r.steps.append("end") },
            stagedCopyIsStillVetted: { _ in r.steps.append("vet"); return r.vetted },
            targetIsTheRunningApp: { _ in r.steps.append("identity"); return r.sameApp },
            armProbation: { _ in r.steps.append("arm"); return !r.armFails },
            disarmProbation: { r.steps.append("disarm") },
            prepareRelaunch: { _ in
                r.steps.append("relaunch")
                if r.relaunchFails { throw Boom.relaunch }
                return UpdateCommit.Undo { r.steps.append("cancelRelaunch") }
            },
            swap: { _, _ in
                r.steps.append("swap")
                if r.swapFails { throw Boom.swap }
            },
            keepPrevious: { _ in r.steps.append("keep") },
            terminate: { r.steps.append("terminate") })
    }

    func testTheStepsRunInOrderAndEndInTheQuit() throws {
        let r = Recorder()
        try commit(r)(update)
        XCTAssertEqual(r.steps, ["isBlocked", "begin", "vet", "identity", "arm", "relaunch", "swap", "keep",
                                 "terminate"])
    }

    /// No probation record (a full disk): nothing is replaced, and no helper
    /// is started.
    func testNoProbationMeansNoSwap() {
        let r = Recorder()
        r.armFails = true
        XCTAssertThrowsError(try commit(r)(update)) {
            XCTAssertEqual($0 as? UpdateCommit.Refusal, .cannotKeepPrevious)
        }
        XCTAssertEqual(r.steps, ["isBlocked", "begin", "vet", "identity", "arm", "disarm", "end"])
    }

    /// Something started after the caller's check: nothing at all happens.
    func testABusyAppIsLeftAlone() {
        let r = Recorder()
        r.blocked = true
        XCTAssertThrowsError(try commit(r)(update)) {
            XCTAssertEqual($0 as? UpdateCommit.Refusal, .busy)
        }
        XCTAssertEqual(r.steps, ["isBlocked"])
    }

    func testAStagedCopyThatChangedIsNotInstalled() {
        let r = Recorder()
        r.vetted = false
        XCTAssertThrowsError(try commit(r)(update)) {
            XCTAssertEqual($0 as? UpdateCommit.Refusal, .stagedCopyChanged)
        }
        XCTAssertEqual(r.steps, ["isBlocked", "begin", "vet", "end"])
    }

    func testAnAppMovedOrReplacedMeanwhileIsNotSwappedOut() {
        let r = Recorder()
        r.sameApp = false
        XCTAssertThrowsError(try commit(r)(update)) {
            XCTAssertEqual($0 as? UpdateCommit.Refusal, .appMoved)
        }
        XCTAssertEqual(r.steps, ["isBlocked", "begin", "vet", "identity", "end"])
    }

    /// No helper to reopen the app: the update stops before the swap, rather
    /// than quit for good or run old code over a new bundle.
    func testNoRelaunchHelperMeansNoSwap() {
        let r = Recorder()
        r.relaunchFails = true
        XCTAssertThrowsError(try commit(r)(update)) {
            guard case .cannotRelaunch? = $0 as? UpdateCommit.Refusal else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(r.steps.contains("swap"))
        XCTAssertEqual(r.steps.suffix(2), ["disarm", "end"])
    }

    func testAFailedSwapUndoesTheHelperAndProbation() {
        let r = Recorder()
        r.swapFails = true
        XCTAssertThrowsError(try commit(r)(update)) {
            XCTAssertEqual($0 as? Boom, .swap)
        }
        XCTAssertEqual(r.steps, ["isBlocked", "begin", "vet", "identity", "arm", "relaunch", "swap",
                                 "cancelRelaunch", "disarm", "end"])
        XCTAssertFalse(r.steps.contains("terminate"))
    }

    // MARK: - The live pieces

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateCommitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// What `targetIsTheRunningApp` compares: a file's identity follows the
    /// file, not its path.
    func testAFileIsKnownByItselfNotByItsPath() throws {
        let original = folder.appendingPathComponent("exe")
        try Data("a".utf8).write(to: original)
        let identity = try XCTUnwrap(FileIdentity(original))
        XCTAssertEqual(FileIdentity(original), identity)

        // Moved: the path no longer leads to it.
        let moved = folder.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: original, to: moved)
        XCTAssertNil(FileIdentity(original))
        XCTAssertEqual(FileIdentity(moved), identity)

        // Something else put at the path: a different file.
        try Data("b".utf8).write(to: original)
        XCTAssertNotEqual(FileIdentity(original), identity)
    }

    @MainActor
    func testTheLiveCommitRefusesAnAppItDoesNotRecognize() throws {
        let installed = folder.appendingPathComponent("Installed.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data().write(to: installed.appendingPathComponent("App"))
        let elsewhere = folder.appendingPathComponent("other")
        try Data().write(to: elsewhere)

        let store = UpdateStateStore(url: folder.appendingPathComponent("state/update-state.json"))
        let activity = AppActivity()
        let commit = UpdateCommit.live(store: store, activity: activity,
                                       expected: SelfUpdater.Expected.running(.main),
                                       runningExecutable: FileIdentity(elsewhere), executableName: "App")
        XCTAssertFalse(commit.targetIsTheRunningApp(folder.appendingPathComponent("Installed.app")))

        let same = UpdateCommit.live(store: store, activity: activity,
                                     expected: SelfUpdater.Expected.running(.main),
                                     runningExecutable: FileIdentity(installed.appendingPathComponent("App")),
                                     executableName: "App")
        XCTAssertTrue(same.targetIsTheRunningApp(folder.appendingPathComponent("Installed.app")))

        // With nothing captured at launch, it never claims to know.
        let unknown = UpdateCommit.live(store: store, activity: activity,
                                        expected: SelfUpdater.Expected.running(.main),
                                        runningExecutable: nil, executableName: "App")
        XCTAssertFalse(unknown.targetIsTheRunningApp(folder.appendingPathComponent("Installed.app")))
    }

    // MARK: - The copy kept for going back

    /// The live install at quit on two folders that stand in for apps, a real
    /// swap and a real store, with stand-ins only for what a test cannot have:
    /// a signed copy and the running executable.
    @MainActor
    private func liveInstallOnFolders(store: UpdateStateStore) throws -> (UpdateCommit, StagedUpdate) {
        let staged = folder.appendingPathComponent("T/NSIRD_holder/App.app", isDirectory: true)
        let installed = folder.appendingPathComponent("Applications/App.app", isDirectory: true)
        for (app, contents) in [(staged, "new"), (installed, "old")] {
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: app.appendingPathComponent("which"))
        }
        var commit = UpdateCommit.liveAtQuit(store: store, activity: AppActivity(),
                                             expected: SelfUpdater.Expected.running(.main))
        commit.stagedCopyIsStillVetted = { _ in true }
        commit.targetIsTheRunningApp = { _ in true }
        return (commit, StagedUpdate(version: "9.9.9", staged: staged, installed: installed))
    }

    private func which(_ app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("which"), encoding: .utf8)
    }

    /// The swap leaves the previous version where the new one was staged, a
    /// folder under the per-user temporary folder, which macOS empties of what
    /// has gone unused for a few days. After an install at quit the next launch
    /// can be later than that, and a new version that then could not stay up
    /// had nothing to go back to. The copy is moved beside the update state.
    @MainActor
    func testThePreviousVersionIsKeptOutsideTheTemporaryFolder() throws {
        let store = UpdateStateStore(url: folder.appendingPathComponent("state/update-state.json"))
        let (commit, update) = try liveInstallOnFolders(store: store)
        try commit(update)

        XCTAssertEqual(which(update.installed), "new")
        let previous = URL(fileURLWithPath: try XCTUnwrap(store.load().probation?.previous))
        XCTAssertTrue(previous.path.hasPrefix(store.url.deletingLastPathComponent().path + "/"),
                      "the copy to go back to is still where the swap left it: \(previous.path)")
        XCTAssertEqual(which(previous), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: update.staged.deletingLastPathComponent().path),
                       "the emptied staging folder is left behind")

        // And it is still a copy to go back to: a version that never stays up
        // is swapped back out for it, and the folder it was kept in goes.
        let tools = UpdateRollback.Tools(isRelease: { _, _ in true },
                                         swap: { try SelfUpdater.swap(staged: $0, into: $1) },
                                         prepareRelaunch: { _ in UpdateCommit.Undo(cancel: {}) },
                                         discard: { SelfUpdater.discard($0) })
        var decisions: [UpdateRollback.LaunchDecision] = []
        for _ in 0...UpdateRollback.maximumLaunches {
            decisions.append(UpdateRollback.atLaunch(runningVersion: "9.9.9", installed: update.installed,
                                                     store: store, tools: tools))
        }
        XCTAssertEqual(decisions.last, .rolledBack)
        XCTAssertEqual(which(update.installed), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.deletingLastPathComponent().path))
    }

    /// With no room to save the probation record (a full disk), the swap went
    /// ahead without it, and a new version that could not stay up had nothing
    /// to go back to. Now nothing is replaced.
    @MainActor
    func testNoProbationRecordMeansNoSwap() throws {
        let state = folder.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        // Nothing can be written there: the same failure as a full disk.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: state.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path) }
        let store = UpdateStateStore(url: state.appendingPathComponent("update-state.json"))
        let (commit, update) = try liveInstallOnFolders(store: store)

        XCTAssertThrowsError(try commit(update), "replaced with no probation to go back to")
        XCTAssertEqual(which(update.installed), "old")
        XCTAssertEqual(which(update.staged), "new")
        XCTAssertNil(store.load().probation)
    }

    @MainActor
    func testTheLiveCommitIsBlockedByWhatAQuitWouldAskAbout() {
        let store = UpdateStateStore(url: folder.appendingPathComponent("state/update-state.json"))
        let activity = AppActivity()
        let commit = UpdateCommit.live(store: store, activity: activity, expected: SelfUpdater.Expected.running(.main))
        XCTAssertFalse(commit.isBlocked())
        activity.recorder = { [.recording] }
        XCTAssertTrue(commit.isBlocked())
        XCTAssertNotNil(activity.quitQuestion)
    }
}
