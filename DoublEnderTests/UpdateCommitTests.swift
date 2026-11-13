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
            armProbation: { _ in r.steps.append("arm") },
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
            terminate: { r.steps.append("terminate") })
    }

    func testTheStepsRunInOrderAndEndInTheQuit() throws {
        let r = Recorder()
        try commit(r)(update)
        XCTAssertEqual(r.steps, ["isBlocked", "begin", "vet", "identity", "arm", "relaunch", "swap", "terminate"])
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
