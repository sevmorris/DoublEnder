import XCTest
@testable import DoublEnder

final class UpdateRollbackTests: XCTestCase {

    private var folder: URL!
    private var store: UpdateStateStore!
    private let installed = URL(fileURLWithPath: "/Applications/App.app")

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateRollbackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = UpdateStateStore(url: folder.appendingPathComponent("state/update-state.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private final class Calls {
        var swaps: [(URL, URL)] = []
        var relaunches: [URL] = []
        var cancelled = 0
        var discarded: [URL] = []
        var isRelease = true
        var swapFails = false
    }

    private enum Boom: Error { case swap }

    private func tools(_ calls: Calls) -> UpdateRollback.Tools {
        UpdateRollback.Tools(
            isRelease: { _, _ in calls.isRelease },
            swap: { previous, installed in
                if calls.swapFails { throw Boom.swap }
                calls.swaps.append((previous, installed))
            },
            prepareRelaunch: { app in
                calls.relaunches.append(app)
                return UpdateCommit.Undo { calls.cancelled += 1 }
            },
            discard: { calls.discarded.append($0) })
    }

    private var previous: URL { folder.appendingPathComponent("holder/App.app") }

    private func arm() {
        UpdateRollback.arm(from: "2.8.3lr", to: "2.9.0lr", previous: previous, installed: installed, store: store,
                           discard: { _ in })
    }

    private var markerExists: Bool { FileManager.default.fileExists(atPath: store.markerURL.path) }

    // MARK: - Probation

    func testArmingRecordsTheProbationAndSetsTheMarker() {
        arm()
        XCTAssertEqual(store.load().probation?.to, "2.9.0lr")
        XCTAssertEqual(store.load().probation?.launches, 0)
        XCTAssertTrue(markerExists)

        UpdateRollback.disarm(store: store)
        XCTAssertNil(store.load().probation)
        XCTAssertFalse(markerExists)
    }

    func testANewVersionGetsTwoStartsToBecomeHealthy() {
        arm()
        let calls = Calls()
        for launch in 1...UpdateRollback.maximumLaunches {
            XCTAssertEqual(UpdateRollback.atLaunch(runningVersion: "2.9.0lr", installed: installed, store: store,
                                                   tools: tools(calls)), .proceed)
            XCTAssertEqual(store.load().probation?.launches, launch)
        }
        XCTAssertTrue(calls.swaps.isEmpty)
        XCTAssertTrue(markerExists, "the helper keeps reopening it while the marker is there")
    }

    /// The third start with no healthy one before it: the previous version is
    /// put back, the bad one is skipped from then on, and the app reopens.
    func testAVersionThatNeverStaysUpIsRolledBack() {
        arm()
        let calls = Calls()
        for _ in 1...UpdateRollback.maximumLaunches {
            _ = UpdateRollback.atLaunch(runningVersion: "2.9.0lr", installed: installed, store: store, tools: tools(calls))
        }
        XCTAssertEqual(UpdateRollback.atLaunch(runningVersion: "2.9.0lr", installed: installed, store: store,
                                               tools: tools(calls)), .rolledBack)

        XCTAssertEqual(calls.swaps.count, 1)
        XCTAssertEqual(calls.swaps.first?.0, previous)
        XCTAssertEqual(calls.swaps.first?.1, installed)
        XCTAssertEqual(calls.relaunches, [installed])
        XCTAssertEqual(calls.discarded, [previous], "the folder holds the failed version after the swap")
        XCTAssertNil(store.load().probation)
        XCTAssertFalse(markerExists)
        XCTAssertTrue(UpdateRollback.isSkipped("2.9.0lr", store: store))
        XCTAssertFalse(UpdateRollback.shouldInstallAutomatically("2.9.0cr", store: store))
    }

    /// Nothing to go back to: the app starts, whatever the version does.
    func testNoUsablePreviousVersionMeansTheAppStarts() {
        arm()
        let calls = Calls()
        calls.isRelease = false
        for _ in 0...UpdateRollback.maximumLaunches {
            XCTAssertEqual(UpdateRollback.atLaunch(runningVersion: "2.9.0lr", installed: installed, store: store,
                                                   tools: tools(calls)), .proceed)
        }
        XCTAssertTrue(calls.swaps.isEmpty)
        XCTAssertNil(store.load().probation)
        XCTAssertFalse(markerExists)
    }

    func testAFailedRollbackSwapCancelsItsHelperAndLetsTheAppStart() {
        arm()
        let calls = Calls()
        calls.swapFails = true
        for _ in 0...UpdateRollback.maximumLaunches {
            XCTAssertEqual(UpdateRollback.atLaunch(runningVersion: "2.9.0lr", installed: installed, store: store,
                                                   tools: tools(calls)), .proceed)
        }
        XCTAssertEqual(calls.cancelled, 1)
        XCTAssertNil(store.load().probation)
    }

    /// The swap never happened, or someone put another version in place.
    func testAnotherVersionClearsAStaleProbation() {
        arm()
        let calls = Calls()
        XCTAssertEqual(UpdateRollback.atLaunch(runningVersion: "2.8.3lr", installed: installed, store: store,
                                               tools: tools(calls)), .proceed)
        XCTAssertNil(store.load().probation)
        XCTAssertEqual(calls.discarded, [previous])
        XCTAssertFalse(markerExists)
    }

    func testAnotherCopyOfTheVersionIsNotCounted() {
        arm()
        let calls = Calls()
        _ = UpdateRollback.atLaunch(runningVersion: "2.9.0lr", installed: URL(fileURLWithPath: "/Volumes/DMG/App.app"),
                                    store: store, tools: tools(calls))
        XCTAssertEqual(store.load().probation?.launches, 0)
    }

    func testHealthyDiscardsThePreviousVersion() {
        arm()
        var discarded: [URL] = []
        UpdateRollback.markHealthy(runningVersion: "2.9.0lr", installed: installed, store: store,
                                   discard: { discarded.append($0) })
        XCTAssertEqual(discarded, [previous])
        XCTAssertNil(store.load().probation)
        XCTAssertFalse(markerExists)
    }

    /// The old version's own quit, right after it armed probation for the new
    /// one, must not clear it.
    func testTheOldVersionsQuitLeavesProbationAlone() {
        arm()
        var discarded: [URL] = []
        UpdateRollback.markHealthy(runningVersion: "2.8.3lr", installed: installed, store: store,
                                   discard: { discarded.append($0) })
        XCTAssertTrue(discarded.isEmpty)
        XCTAssertNotNil(store.load().probation)
        XCTAssertTrue(markerExists)
    }

    /// A second copy of the new version, run from a disk image or another
    /// folder, shares this state. Its good health says nothing about the copy
    /// that was replaced, and must not delete what that copy can go back to.
    func testAnotherCopysHealthLeavesProbationAlone() {
        arm()
        var discarded: [URL] = []
        UpdateRollback.markHealthy(runningVersion: "2.9.0lr", installed: URL(fileURLWithPath: "/Volumes/DMG/App.app"),
                                   store: store, discard: { discarded.append($0) })
        XCTAssertTrue(discarded.isEmpty)
        XCTAssertNotNil(store.load().probation)
        XCTAssertTrue(markerExists)
    }

    // MARK: - A quit before the recorder opened

    private func start(_ calls: Calls) -> UpdateRollback.LaunchDecision {
        UpdateRollback.atLaunch(runningVersion: "2.9.0lr", installed: installed, store: store, tools: tools(calls))
    }

    private func quitBeforeTheRecorder(version: String = "2.9.0lr", installed copy: URL? = nil) {
        UpdateRollback.noteCleanQuitBeforeHealthy(runningVersion: version, installed: copy ?? installed, store: store)
    }

    /// After the unprompted relaunch a guest quits while "Checking for
    /// updates…" is still up, and again when the helper reopens the app. Those
    /// starts ended because someone quit, not because the version cannot stay
    /// up: however often it happens, nothing is rolled back.
    func testQuittingBeforeTheRecorderOpensNeverRollsAGoodVersionBack() {
        arm()
        let calls = Calls()
        for _ in 1...5 {
            XCTAssertEqual(start(calls), .proceed)
            quitBeforeTheRecorder()
        }
        XCTAssertTrue(calls.swaps.isEmpty, "a good version was rolled back because it was quit")
        XCTAssertFalse(UpdateRollback.isSkipped("2.9.0lr", store: store))
        XCTAssertEqual(store.load().probation?.launches, 0)
    }

    /// The marker is what the relaunch helper watches: gone, it leaves the app
    /// closed instead of reopening one the guest just quit.
    func testAQuitBeforeTheRecorderTellsTheHelperToStop() {
        arm()
        _ = start(Calls())
        XCTAssertTrue(markerExists)
        quitBeforeTheRecorder()
        XCTAssertFalse(markerExists)
        XCTAssertNotNil(store.load().probation, "the version has still to show it stays up")
    }

    /// Starts that ended by themselves still count, with quits in between.
    func testCrashesStillCountAroundAQuit() {
        arm()
        let calls = Calls()
        XCTAssertEqual(start(calls), .proceed)   // crashed
        XCTAssertEqual(start(calls), .proceed)   // quit before the recorder
        quitBeforeTheRecorder()
        XCTAssertEqual(start(calls), .proceed)   // crashed
        XCTAssertEqual(start(calls), .rolledBack)
        XCTAssertEqual(calls.swaps.count, 1)
    }

    /// The old version quitting to make way, and a second copy of the new one.
    func testOnlyTheCopyOnProbationsQuitIsNoted() {
        arm()
        _ = start(Calls())
        quitBeforeTheRecorder(version: "2.8.3lr")
        quitBeforeTheRecorder(installed: URL(fileURLWithPath: "/Volumes/DMG/App.app"))
        XCTAssertEqual(store.load().probation?.launches, 1)
        XCTAssertTrue(markerExists)
    }

    /// Cloud found a newer version at the first start of the last one.
    func testArmingOverAnUnprovenVersionDiscardsItsPreviousCopy() {
        arm()
        var discarded: [URL] = []
        let newer = folder.appendingPathComponent("holder2/App.app")
        UpdateRollback.arm(from: "2.9.0lr", to: "2.9.1lr", previous: newer, installed: installed, store: store,
                           discard: { discarded.append($0) })
        XCTAssertEqual(discarded, [previous])
        XCTAssertEqual(store.load().probation?.previous, newer.path)
    }

    /// With no room for the new record, the older one stays whole, copy and
    /// all, and the caller is told so it replaces nothing.
    func testArmingThatCannotSaveChangesNothing() throws {
        arm()
        let stateFolder = store.url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stateFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateFolder.path) }
        var discarded: [URL] = []
        let saved = UpdateRollback.arm(from: "2.9.0lr", to: "2.9.1lr", previous: folder.appendingPathComponent("holder2/App.app"),
                                       installed: installed, store: store, discard: { discarded.append($0) })
        XCTAssertFalse(saved)
        XCTAssertEqual(discarded, [])
        XCTAssertEqual(store.load().probation?.previous, previous.path)
    }

    // MARK: - Keeping the previous version

    private func makePrevious() throws {
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: previous.appendingPathComponent("which"))
    }

    private var keptCopies: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: store.keptCopiesURL, includingPropertiesForKeys: nil)) ?? []
    }

    func testThePreviousVersionMovesBesideTheStateAndTheRecordFollows() throws {
        try makePrevious()
        arm()
        UpdateRollback.keepPrevious(at: previous, store: store)
        let kept = URL(fileURLWithPath: try XCTUnwrap(store.load().probation?.previous))
        XCTAssertEqual(kept.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path,
                       store.keptCopiesURL.standardizedFileURL.path)
        XCTAssertEqual(kept.lastPathComponent, "App.app")
        XCTAssertEqual(try String(contentsOf: kept.appendingPathComponent("which"), encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.deletingLastPathComponent().path))
        XCTAssertTrue(store.keptCopiesURL.path.hasSuffix(".noindex"), "Spotlight would list the old copy")
    }

    /// An app on another volume cannot be renamed into Application Support, and
    /// is never copied there: it stays where the swap left it.
    func testAPreviousVersionThatCannotBeRenamedStaysPut() throws {
        try makePrevious()
        arm()
        UpdateRollback.keepPrevious(at: previous, store: store, move: { _, _ in throw CocoaError(.fileWriteUnknown) })
        XCTAssertEqual(store.load().probation?.previous, previous.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))
        XCTAssertEqual(keptCopies, [])
    }

    /// Moved, but the record that says so cannot be saved: it goes back where
    /// the record still says it is.
    func testAPreviousVersionWhoseRecordCannotFollowGoesBack() throws {
        try makePrevious()
        arm()
        let stateFolder = store.url.deletingLastPathComponent()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateFolder.path) }
        var moves = 0
        UpdateRollback.keepPrevious(at: previous, store: store, move: { from, to in
            try UpdateRollback.rename(from, to: to)
            moves += 1
            // The disk fills just after the rename.
            if moves == 1 {
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stateFolder.path)
            }
        })
        XCTAssertEqual(moves, 2)
        XCTAssertEqual(store.load().probation?.previous, previous.path)
        XCTAssertEqual(try String(contentsOf: previous.appendingPathComponent("which"), encoding: .utf8), "old")
        XCTAssertEqual(keptCopies, [])
    }

    /// Only the copy probation names is moved: a call for any other leaves it.
    func testOnlyTheCopyOnProbationIsMoved() throws {
        try makePrevious()
        UpdateRollback.keepPrevious(at: previous, store: store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))
        XCTAssertEqual(keptCopies, [])
    }

    func testTheRenameNeverReplacesAnything() throws {
        let a = folder.appendingPathComponent("a"), b = folder.appendingPathComponent("b")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        XCTAssertThrowsError(try UpdateRollback.rename(a, to: b))
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "b")
    }

    // MARK: - What not to install unasked

    func testTwoFailuresRestTheAutomaticInstallForADay() {
        let now = Date()
        XCTAssertTrue(UpdateRollback.shouldInstallAutomatically("2.9.0cr", store: store, now: now))
        UpdateRollback.recordFailure(of: "2.9.0cr", store: store, now: now)
        XCTAssertTrue(UpdateRollback.shouldInstallAutomatically("2.9.0cr", store: store, now: now))
        UpdateRollback.recordFailure(of: "2.9.0cr", store: store, now: now)
        XCTAssertFalse(UpdateRollback.shouldInstallAutomatically("2.9.0cr", store: store, now: now))
        XCTAssertTrue(UpdateRollback.shouldInstallAutomatically("2.9.0cr", store: store,
                                                                now: now.addingTimeInterval(UpdateRollback.failureRest + 1)))
        // A newer version starts afresh, and the old count is dropped.
        XCTAssertTrue(UpdateRollback.shouldInstallAutomatically("2.9.1cr", store: store, now: now))
        UpdateRollback.recordFailure(of: "2.9.1cr", store: store, now: now)
        XCTAssertEqual(Set(store.load().failures.keys), ["2.9.1"])
    }

    func testAnUnreadableStateIsAnEmptyOne() throws {
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), UpdateState())
        XCTAssertEqual(UpdateRollback.atLaunch(runningVersion: "2.9.0lr", installed: installed, store: store,
                                               tools: tools(Calls())), .proceed)
    }

    func testTheTestRunsStoreIsNotTheAppsOwn() {
        XCTAssertTrue(UpdateStateStore.app.url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    func testTheJournalKeepsItsPaths() {
        XCTAssertEqual(store.journal, [])
        store.journal = ["/a", "/b"]
        XCTAssertEqual(store.journal, ["/a", "/b"])
        store.journal = []
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.journalURL.path))
    }

    // MARK: - Self-test

    /// A bundle whose executable is never run: these tests hand
    /// `UpdateSelfTest.passes` a runner of their own. Running a binary inside a
    /// bundle whose signature does not match makes macOS treat it as an app
    /// launch and put up a "damaged" dialog until someone answers it.
    private func makeBundle(selfTest: Bool?) throws -> URL {
        let app = folder.appendingPathComponent("Probe.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data().write(to: macOS.appendingPathComponent("Probe"))
        var info: [String: Any] = ["CFBundleExecutable": "Probe", "CFBundleShortVersionString": "2.9.0lr"]
        if let selfTest { info[UpdateSelfTest.infoKey] = selfTest }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    func testTheSelfTestRunsTheCopyWhenItSaysItAnswers() throws {
        let app = try makeBundle(selfTest: true)
        var ran: [String] = []
        XCTAssertTrue(UpdateSelfTest.passes(app, run: { binary, arguments, _, _ in
            ran = [binary] + arguments
            return .success
        }))
        XCTAssertEqual(ran, [app.appendingPathComponent("Contents/MacOS/Probe").path, UpdateSelfTest.argument])
    }

    /// A copy that fails, hangs past the deadline, or is stopped, fails.
    func testACopyThatDoesNotStartFails() throws {
        let app = try makeBundle(selfTest: true)
        for outcome in [SelfUpdater.Tools.Outcome.failure, .timedOut, .cancelled] {
            XCTAssertFalse(UpdateSelfTest.passes(app, run: { _, _, _, _ in outcome }), "\(outcome)")
        }
    }

    /// A copy from before the self-test would open as a second recorder.
    func testACopyThatDoesNotAnswerIsNotRun() throws {
        for selfTest in [nil, false] as [Bool?] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("Probe.app"))
            let app = try makeBundle(selfTest: selfTest)
            var ran = false
            XCTAssertTrue(UpdateSelfTest.passes(app, run: { _, _, _, _ in ran = true; return .failure }))
            XCTAssertFalse(ran)
        }
    }

    func testABundleWithoutAnInfoPlistFails() {
        XCTAssertFalse(UpdateSelfTest.passes(folder.appendingPathComponent("Nothing.app"),
                                             run: { _, _, _, _ in .success }))
    }

    func testThisBuildSaysItAnswers() {
        XCTAssertEqual(Bundle.main.infoDictionary?[UpdateSelfTest.infoKey] as? Bool, true)
    }

    func testTheVersionIsReadFromTheFile() throws {
        let app = try makeBundle(selfTest: nil)
        XCTAssertEqual(bundleVersion(at: app), "2.9.0lr")
        XCTAssertNil(bundleVersion(at: folder.appendingPathComponent("Nothing.app")))
    }
}
