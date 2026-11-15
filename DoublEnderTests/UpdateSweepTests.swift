import XCTest
@testable import DoublEnder

final class UpdateSweepTests: XCTestCase {

    private var folder: URL!
    private var temporary: URL!
    private var store: UpdateStateStore!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateSweepTests-\(UUID().uuidString)", isDirectory: true)
        temporary = folder.appendingPathComponent("T", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        store = UpdateStateStore(url: folder.appendingPathComponent("state/update-state.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeFolder(_ name: String, in parent: URL, created: Date) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("mount"), withIntermediateDirectories: true)
        try Data("dmg".utf8).write(to: url.appendingPathComponent("update.dmg"))
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testOldScratchFoldersGoAndRecentOnesStay() throws {
        let now = Date()
        let start = now.addingTimeInterval(-60)
        let old = try makeFolder("\(SelfUpdater.scratchPrefix)old", in: temporary, created: now.addingTimeInterval(-7200))
        // A sibling app may be using it.
        let recent = try makeFolder("\(SelfUpdater.scratchPrefix)recent", in: temporary, created: now.addingTimeInterval(-600))
        // Made by this run.
        let mine = try makeFolder("\(SelfUpdater.scratchPrefix)mine", in: temporary, created: now)
        let unrelated = try makeFolder("Something-else", in: temporary, created: now.addingTimeInterval(-7200))

        UpdateSweep.sweep(holders: [], temporaryDirectory: temporary, processStart: start, now: now,
                          tools: UpdateSweep.Tools(isMountPoint: { _ in false }, detach: { _ in }))

        XCTAssertFalse(exists(old))
        XCTAssertTrue(exists(recent))
        XCTAssertTrue(exists(mine))
        XCTAssertTrue(exists(unrelated))
    }

    func testAMountedImageIsDetachedFirst() throws {
        let now = Date()
        let old = try makeFolder("\(SelfUpdater.scratchPrefix)old", in: temporary, created: now.addingTimeInterval(-7200))
        // /var and /private/var are the same folder; compare what is real.
        func key(_ url: URL) -> String { url.resolvingSymlinksInPath().path }
        let mount = key(old.appendingPathComponent("mount"))
        var mounted: Set<String> = [mount]
        var detached: [String] = []
        UpdateSweep.sweep(holders: [], temporaryDirectory: temporary, processStart: now, now: now,
                          tools: UpdateSweep.Tools(isMountPoint: { mounted.contains(key($0)) },
                                                   detach: { detached.append(key($0)); mounted.remove(key($0)) }))
        XCTAssertEqual(detached, [mount])
        XCTAssertFalse(exists(old))
    }

    /// Removing the folder would walk into the volume.
    func testAnImageThatWillNotDetachIsLeftAlone() throws {
        let now = Date()
        let old = try makeFolder("\(SelfUpdater.scratchPrefix)old", in: temporary, created: now.addingTimeInterval(-7200))
        UpdateSweep.sweep(holders: [], temporaryDirectory: temporary, processStart: now, now: now,
                          tools: UpdateSweep.Tools(isMountPoint: { _ in true }, detach: { _ in }))
        XCTAssertTrue(exists(old))
    }

    @MainActor
    func testStagingFoldersFromEarlierRunsGoExceptTheOneOnProbation() throws {
        let now = Date()
        let abandoned = try makeFolder("NSIRD_abandoned", in: folder, created: now)
        let onProbation = try makeFolder("NSIRD_previous", in: folder, created: now)
        store.journal = [abandoned.path, onProbation.path]
        UpdateRollback.arm(from: "1", to: "2", previous: onProbation.appendingPathComponent("App.app"),
                           installed: URL(fileURLWithPath: "/Applications/App.app"), store: store, discard: { _ in })

        let leftovers = UpdateSweep.takeLeftovers(store: store)
        XCTAssertEqual(leftovers.map(\.path), [abandoned.standardizedFileURL.path])
        XCTAssertEqual(store.journal, [], "taken off the journal")

        UpdateSweep.sweep(holders: leftovers, temporaryDirectory: temporary, processStart: now, now: now,
                          tools: UpdateSweep.Tools(isMountPoint: { _ in false }, detach: { _ in }))
        XCTAssertFalse(exists(abandoned))
        XCTAssertTrue(exists(onProbation))
    }

    /// Two copies of the app share the journal: the installed one, and one
    /// opened from the disk image while it runs, which sweeps at launch before
    /// it hands off. The running copy holds its staging folder locked while it
    /// downloads into it or keeps a staged copy there. The sweep used to take
    /// every folder on the journal, and deleted that one.
    @MainActor
    func testAStagingFolderAnotherCopyHoldsIsLeftOnTheJournal() throws {
        let now = Date()
        let abandoned = try makeFolder("NSIRD_abandoned", in: folder, created: now)
        let inUse = try makeFolder("NSIRD_in_use", in: folder, created: now)
        store.journal = [abandoned.path, inUse.path]
        // The other copy's lock, taken as it takes it, with open(2) and no
        // help from the app, so this runs against any version of the sweep.
        var fd = open(inUse.path, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { if fd >= 0 { close(fd) } }

        let leftovers = UpdateSweep.takeLeftovers(store: store)
        XCTAssertEqual(leftovers.map(\.path), [abandoned.standardizedFileURL.path],
                       "the sweep took a folder another copy is still using")
        XCTAssertEqual(store.journal, [inUse.path], "left on the journal for the copy using it")

        // That copy ends, however it ends: the kernel drops its lock, and the
        // next launch takes what it left.
        close(fd)
        fd = -1
        XCTAssertEqual(UpdateSweep.takeLeftovers(store: store).map(\.path), [inUse.standardizedFileURL.path])
        XCTAssertEqual(store.journal, [])
    }

    func testTheSystemMountCheckSeesNoMountInAPlainFolder() throws {
        XCTAssertFalse(UpdateSweep.Tools.system.isMountPoint(temporary))
        XCTAssertFalse(UpdateSweep.Tools.system.isMountPoint(folder.appendingPathComponent("missing")))
    }
}
