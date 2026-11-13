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
        UpdateRollback.markHealthy(runningVersion: "2.9.0lr", store: store, discard: { discarded.append($0) })
        XCTAssertEqual(discarded, [previous])
        XCTAssertNil(store.load().probation)
        XCTAssertFalse(markerExists)
    }

    /// The old version's own quit, right after it armed probation for the new
    /// one, must not clear it.
    func testTheOldVersionsQuitLeavesProbationAlone() {
        arm()
        var discarded: [URL] = []
        UpdateRollback.markHealthy(runningVersion: "2.8.3lr", store: store, discard: { discarded.append($0) })
        XCTAssertTrue(discarded.isEmpty)
        XCTAssertNotNil(store.load().probation)
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
