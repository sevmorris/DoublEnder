import XCTest
@testable import DoublEnder

/// Runs the relaunch helper for real, with a stand-in for `/usr/bin/open` that
/// writes down each call, and a `sleep` process standing in for the app that
/// is quitting.
final class UpdateRelauncherTests: XCTestCase {

    private var folder: URL!
    private var log: URL!
    private var marker: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateRelauncherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        log = folder.appendingPathComponent("opened.log")
        marker = folder.appendingPathComponent("marker")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// An opener that logs its arguments and then runs `then`.
    private func opener(_ then: String) throws -> String {
        let script = folder.appendingPathComponent("opener.sh")
        try """
            #!/bin/sh
            echo "$@" >> "\(log.path)"
            \(then)
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private func startOldApp(seconds: Double) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [String(seconds)]
        try process.run()
        return process
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval = 20) -> Int32? {
        let end = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < end { usleep(50_000) }
        return process.isRunning ? nil : process.terminationStatus
    }

    private var openedLines: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private let app = URL(fileURLWithPath: "/Applications/Some App.app")

    func testItOpensTheAppOnceTheOldOneHasGone() throws {
        let old = try startOldApp(seconds: 0.5)
        let helper = try UpdateRelauncher.prepare(toOpen: app, after: old.processIdentifier, marker: nil,
                                                  opener: try opener("exit 0"))
        // Nothing is opened while the old process is still there.
        usleep(200_000)
        XCTAssertTrue(openedLines.isEmpty)
        XCTAssertEqual(waitForExit(helper), 0)
        XCTAssertEqual(openedLines, [app.path])
    }

    /// The new version keeps dying before it is healthy: it is opened again,
    /// three times in all, which is what its own rollback counts on.
    func testANewVersionThatDiesOnProbationIsReopened() throws {
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        let old = try startOldApp(seconds: 0.1)
        let helper = try UpdateRelauncher.prepare(toOpen: app, after: old.processIdentifier, marker: marker,
                                                  opener: try opener("exit 0"))
        XCTAssertEqual(waitForExit(helper), 1)
        XCTAssertEqual(openedLines, Array(repeating: "-W \(app.path)", count: 3))
    }

    /// Healthy: the marker goes while the app runs, and the helper is done.
    func testAHealthyNewVersionIsOpenedOnce() throws {
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        let old = try startOldApp(seconds: 0.1)
        let helper = try UpdateRelauncher.prepare(toOpen: app, after: old.processIdentifier, marker: marker,
                                                  opener: try opener("rm -f \"\(marker.path)\"; sleep 30"))
        XCTAssertEqual(waitForExit(helper), 0)
        XCTAssertEqual(openedLines, ["-W \(app.path)"])
    }

    /// The swap failed: the helper is stopped before it opens anything.
    func testACancelledHelperOpensNothing() throws {
        let old = try startOldApp(seconds: 1)
        let helper = try UpdateRelauncher.prepare(toOpen: app, after: old.processIdentifier, marker: nil,
                                                  opener: try opener("exit 0"))
        helper.terminate()
        _ = waitForExit(helper)
        _ = waitForExit(old)
        usleep(300_000)
        XCTAssertTrue(openedLines.isEmpty)
    }
}
