import XCTest
@testable import DoublEnder

/// The lock one copy of the app holds on what it is using, which another copy
/// checks before it deletes a staging folder or offers a take.
final class InUseLockTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("InUseLockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testAFileIsHeldUntilReleased() throws {
        let file = folder.appendingPathComponent("Ada.m4a")
        try Data("take".utf8).write(to: file)
        XCTAssertFalse(InUseLock.isHeld(file))
        let lock = try XCTUnwrap(InUseLock.take(file).lock)
        XCTAssertTrue(InUseLock.isHeld(file))
        guard case .heldElsewhere = InUseLock.take(file) else { return XCTFail("taken twice") }
        lock.release()
        XCTAssertFalse(InUseLock.isHeld(file))
        lock.release()   // twice is harmless
    }

    /// The staging folders are locked as folders, with nothing put in them.
    func testAFolderCanBeHeld() throws {
        let staging = folder.appendingPathComponent("NSIRD_staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var lock = InUseLock.take(staging).lock
        XCTAssertNotNil(lock)
        XCTAssertTrue(InUseLock.isHeld(staging))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
        lock = nil   // dropping it lets go
        XCTAssertFalse(InUseLock.isHeld(staging))
    }

    /// What is gone is nobody's: not held, and not lockable.
    func testSomethingMissingIsNotHeld() {
        let missing = folder.appendingPathComponent("gone.m4a")
        XCTAssertFalse(InUseLock.isHeld(missing))
        guard case .unavailable = InUseLock.take(missing) else { return XCTFail("locked a missing file") }
    }

    /// Another process sees the lock, as another copy of the app would.
    func testAnotherProcessSeesItHeld() throws {
        let file = folder.appendingPathComponent("Ada.m4a")
        try Data("take".utf8).write(to: file)
        let lock = try XCTUnwrap(InUseLock.take(file).lock)
        defer { lock.release() }
        let check = Process()
        // perl ships with macOS; /usr/bin/python3 may be the stub that asks
        // to install the command line tools.
        check.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        check.arguments = ["-e", "use Fcntl qw(:flock); open(my $f, '<', $ARGV[0]) or exit 1; "
                                 + "exit(flock($f, LOCK_SH | LOCK_NB) ? 0 : 3)", file.path]
        try check.run()
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 3, "another process did not see the lock")
    }
}
