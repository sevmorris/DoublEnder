import XCTest
@testable import DoublEnder

/// A copy on its disk image or translocated from Downloads can never update
/// itself; `MoveToApplications` puts it where it can. These run on stand-in
/// bundles in a temporary folder: nothing is launched, nothing reaches the real
/// Applications folder or the Trash, and "signed" is a key in the stand-in's
/// Info.plist.
final class MoveToApplicationsTests: XCTestCase {

    private var folder: URL!
    private let bundleID = "io.github.sevmorris.Test"
    private let version = "2.9.0cr"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoveToApplicationsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - The world

    private var systemApplications: URL { folder.appendingPathComponent("Applications", isDirectory: true) }
    private var homeApplications: URL { folder.appendingPathComponent("home/Applications", isDirectory: true) }
    private var volume: URL { folder.appendingPathComponent("Volumes/Test", isDirectory: true) }
    private var running: URL { volume.appendingPathComponent("Test.app") }

    private final class World {
        var stuck = true
        var translocated = false
        var diskImage: URL?
        var original: URL?
        var writable: Set<String> = []
        var copyFails = false
        var quarantineStays = false
        var stagedIsRelease = true
        var trashed: [URL] = []
        var holders: [URL] = []
    }

    @discardableResult
    private func makeApp(at url: URL, version: String, bundleID: String? = nil, signed: Bool = true,
                         quarantined: Bool = false) throws -> URL {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: contents.appendingPathComponent("MacOS/Test"))
        let info: [String: Any] = ["CFBundleIdentifier": bundleID ?? self.bundleID, "CFBundleExecutable": "Test",
                                   "CFBundleShortVersionString": version, "TestSigned": signed]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if quarantined {
            for item in [url, contents.appendingPathComponent("MacOS/Test")] {
                let value = "0081;00000000;Test;"
                XCTAssertEqual(setxattr(item.path, MoveToApplications.quarantineAttribute, value, value.utf8.count, 0, 0), 0)
            }
        }
        return url
    }

    private func info(_ app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private func tools(_ world: World) -> MoveToApplications.Tools {
        let bundleID = self.bundleID
        let folder = self.folder!
        return MoveToApplications.Tools(
            isStuck: { _ in world.stuck },
            isTranslocated: { _ in world.translocated },
            diskImageVolume: { _ in world.diskImage },
            originalLocation: { _ in world.original },
            isRelease: { [unowned self] app in
                guard let info = info(app), info["CFBundleIdentifier"] as? String == bundleID,
                      info["TestSigned"] as? Bool == true else { return false }
                // The copy being checked before it is installed.
                if app.deletingLastPathComponent().lastPathComponent.hasPrefix("holder") { return world.stagedIsRelease }
                return true
            },
            version: { bundleVersion(at: $0) },
            exists: { FileManager.default.fileExists(atPath: $0.path) },
            isWritableFolder: { world.writable.contains($0.standardizedFileURL.path) },
            applicationsFolders: [systemApplications, homeApplications],
            makeFolder: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
            makeHolder: { _ in
                let holder = folder.appendingPathComponent("holder-\(world.holders.count)", isDirectory: true)
                try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
                world.holders.append(holder)
                return holder
            },
            copy: { from, to in
                if world.copyFails { throw MoveToApplications.Failure.copy }
                try FileManager.default.copyItem(at: from, to: to)
            },
            removeQuarantine: { url in
                if !world.quarantineStays { MoveToApplications.removeQuarantine(under: url) }
            },
            hasQuarantine: { MoveToApplications.hasQuarantine($0) },
            swap: { try SelfUpdater.swap(staged: $0, into: $1) },
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            removeItem: { try? FileManager.default.removeItem(at: $0) },
            trash: { world.trashed.append($0) })
    }

    private func decide(_ world: World, lastMove: Date? = nil, now: Date = Date()) -> MoveToApplications.Decision {
        MoveToApplications.decide(app: running, appName: "Test", version: version, lastMove: lastMove, now: now,
                                  tools: tools(world))
    }

    /// Where an `openInstalled` decision points, as a path: `URL` puts a slash
    /// after a folder that exists, so two URLs for one bundle can differ.
    private func installedPath(_ decision: MoveToApplications.Decision) -> (path: String, ejecting: URL?)? {
        guard case .openInstalled(let url, let volume) = decision else { return nil }
        return (url.standardizedFileURL.path, volume)
    }

    private func adminWorld() -> World {
        let world = World()
        world.diskImage = volume
        world.writable = [systemApplications.standardizedFileURL.path]
        return world
    }

    // MARK: - Deciding

    func testACopyThatCanUpdateItselfStaysWhereItIs() throws {
        let world = adminWorld()
        world.stuck = false
        XCTAssertEqual(decide(world), .stay)
    }

    func testACopyOnItsDiskImageIsOfferedTheMove() throws {
        try FileManager.default.createDirectory(at: systemApplications, withIntermediateDirectories: true)
        let world = adminWorld()
        guard case .offer(let offer) = decide(world) else { return XCTFail("no offer") }
        XCTAssertEqual(offer.destination, systemApplications.appendingPathComponent("Test.app"))
        XCTAssertFalse(offer.replacing)
        XCTAssertEqual(offer.origin, .diskImage(volume: volume))
        XCTAssertTrue(MoveToApplications.explanation(for: offer).contains("running from its disk image"))
    }

    func testATranslocatedCopyKnowsWhereItsDownloadIs() throws {
        try FileManager.default.createDirectory(at: systemApplications, withIntermediateDirectories: true)
        let world = adminWorld()
        world.diskImage = nil
        world.translocated = true
        world.original = folder.appendingPathComponent("Downloads/Test.app")
        guard case .offer(let offer) = decide(world) else { return XCTFail("no offer") }
        XCTAssertEqual(offer.origin, .downloaded(original: world.original))
        XCTAssertTrue(MoveToApplications.explanation(for: offer).contains("downloaded to"))
    }

    /// A standard account cannot write to /Applications; its own Applications
    /// folder takes the copy, and is made if it is not there yet.
    func testWithoutAdministratorRightsItGoesToTheHomeApplicationsFolder() throws {
        try FileManager.default.createDirectory(at: systemApplications, withIntermediateDirectories: true)
        let world = adminWorld()
        world.writable = [homeApplications.deletingLastPathComponent().standardizedFileURL.path]
        guard case .offer(let offer) = decide(world) else { return XCTFail("no offer") }
        XCTAssertEqual(offer.destination, homeApplications.appendingPathComponent("Test.app"))
    }

    func testNowhereToWriteMeansNoOffer() throws {
        try FileManager.default.createDirectory(at: systemApplications, withIntermediateDirectories: true)
        let world = adminWorld()
        world.writable = []
        XCTAssertEqual(decide(world), .stay)
    }

    /// The guest opened the disk image again, though the app is installed: the
    /// installed copy is the one that keeps up to date, so it is opened, and
    /// the image ejected.
    func testAnInstalledCopyAtLeastAsNewIsOpenedInstead() throws {
        let world = adminWorld()
        for installedVersion in [version, "2.9.1cr"] {
            let installed = systemApplications.appendingPathComponent("Test.app")
            try? FileManager.default.removeItem(at: installed)
            try makeApp(at: installed, version: installedVersion)
            let decision = installedPath(decide(world))
            XCTAssertEqual(decision?.path, installed.standardizedFileURL.path, installedVersion)
            XCTAssertEqual(decision?.ejecting, volume, installedVersion)
        }
    }

    func testAnInstalledCopyInTheHomeFolderCountsToo() throws {
        let world = adminWorld()
        let installed = homeApplications.appendingPathComponent("Test.app")
        try makeApp(at: installed, version: version)
        XCTAssertEqual(installedPath(decide(world))?.path, installed.standardizedFileURL.path)
    }

    func testAnOlderInstalledCopyIsReplaced() throws {
        let world = adminWorld()
        try makeApp(at: systemApplications.appendingPathComponent("Test.app"), version: "2.8.4cr")
        guard case .offer(let offer) = decide(world) else { return XCTFail("no offer") }
        XCTAssertTrue(offer.replacing)
        XCTAssertTrue(MoveToApplications.explanation(for: offer).contains("older copy there is replaced"))
    }

    /// A development build, or anything else by that name, is never replaced
    /// or opened.
    func testSomethingElseAtTheDestinationIsLeftAlone() throws {
        let world = adminWorld()
        try makeApp(at: systemApplications.appendingPathComponent("Test.app"), version: "2.8.4cr", signed: false)
        XCTAssertEqual(decide(world), .stay)
        try FileManager.default.removeItem(at: systemApplications.appendingPathComponent("Test.app"))
        try makeApp(at: systemApplications.appendingPathComponent("Test.app"), version: "3.0.0", bundleID: "com.other.App")
        XCTAssertEqual(decide(world), .stay)
    }

    /// A move a moment ago whose new copy came up stuck as well: no hand-over
    /// again and again.
    func testAMoveAMomentAgoIsNotOfferedAgain() throws {
        try FileManager.default.createDirectory(at: systemApplications, withIntermediateDirectories: true)
        let world = adminWorld()
        let now = Date()
        XCTAssertEqual(decide(world, lastMove: now.addingTimeInterval(-10), now: now), .stay)
        guard case .offer = decide(world, lastMove: now.addingTimeInterval(-MoveToApplications.retryAfter - 1), now: now)
        else { return XCTFail("no offer once the pause was over") }
    }

    func testVersionsCompareByTheirNumbers() {
        XCTAssertTrue(MoveToApplications.isOlder("2.8.4cr", than: "2.9.0cr"))
        XCTAssertTrue(MoveToApplications.isOlder("2.9.0", than: "2.10.0cr"))
        XCTAssertFalse(MoveToApplications.isOlder("2.9.0cr", than: "2.9.0lr"))
        XCTAssertFalse(MoveToApplications.isOlder("2.9.1cr", than: "2.9.0cr"))
    }

    // MARK: - Moving

    private func offer(_ world: World) throws -> MoveToApplications.Offer {
        guard case .offer(let offer) = decide(world) else { throw XCTSkip("no offer") }
        return offer
    }

    /// The copy is in place without its download mark, so it is not
    /// translocated again, and the download goes to the Trash.
    func testAMovePutsACleanCopyInPlaceAndTrashesTheDownload() throws {
        try FileManager.default.createDirectory(at: systemApplications, withIntermediateDirectories: true)
        try makeApp(at: running, version: version, quarantined: true)
        let world = adminWorld()
        world.diskImage = nil
        world.translocated = true
        world.original = folder.appendingPathComponent("Downloads/Test.app")

        let installed = try MoveToApplications.move(try offer(world), version: version, tools: tools(world))
        XCTAssertEqual(installed.path, systemApplications.appendingPathComponent("Test.app").path)
        XCTAssertEqual(bundleVersion(at: installed), version)
        XCTAssertFalse(MoveToApplications.hasQuarantine(installed))
        XCTAssertFalse(MoveToApplications.hasQuarantine(installed.appendingPathComponent("Contents/MacOS/Test")))
        XCTAssertEqual(world.trashed, [world.original])
        XCTAssertTrue(FileManager.default.fileExists(atPath: running.path), "the running copy was touched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.holders[0].path))
    }

    /// A disk image's copy stays where it is: the image is ejected afterwards.
    func testAMoveFromADiskImageTrashesNothing() throws {
        try FileManager.default.createDirectory(at: systemApplications, withIntermediateDirectories: true)
        try makeApp(at: running, version: version)
        let world = adminWorld()
        _ = try MoveToApplications.move(try offer(world), version: version, tools: tools(world))
        XCTAssertTrue(world.trashed.isEmpty)
    }

    func testAMoveReplacesAnOlderCopyInOneStep() throws {
        let destination = systemApplications.appendingPathComponent("Test.app")
        try makeApp(at: destination, version: "2.8.4cr")
        try makeApp(at: running, version: version)
        let world = adminWorld()
        _ = try MoveToApplications.move(try offer(world), version: version, tools: tools(world))
        XCTAssertEqual(bundleVersion(at: destination), version)
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.holders[0].path), "the older copy was left behind")
    }

    func testAMoveMakesTheHomeApplicationsFolder() throws {
        try FileManager.default.createDirectory(at: systemApplications, withIntermediateDirectories: true)
        try makeApp(at: running, version: version)
        let world = adminWorld()
        world.writable = [homeApplications.deletingLastPathComponent().standardizedFileURL.path]
        try FileManager.default.createDirectory(at: homeApplications.deletingLastPathComponent(), withIntermediateDirectories: true)
        let installed = try MoveToApplications.move(try offer(world), version: version, tools: tools(world))
        XCTAssertEqual(installed.path, homeApplications.appendingPathComponent("Test.app").path)
        XCTAssertEqual(bundleVersion(at: installed), version)
    }

    /// Every failure leaves what was there as it was, and nothing behind.
    func testAFailedMoveChangesNothing() throws {
        let destination = systemApplications.appendingPathComponent("Test.app")
        try makeApp(at: running, version: version, quarantined: true)
        let cases: [(String, (World) -> Void, MoveToApplications.Failure)] = [
            ("copy", { $0.copyFails = true }, .copy),
            ("quarantine", { $0.quarantineStays = true }, .quarantine),
            ("verify", { $0.stagedIsRelease = false }, .notVerified),
        ]
        for (name, breakIt, expected) in cases {
            try? FileManager.default.removeItem(at: destination)
            try makeApp(at: destination, version: "2.8.4cr")
            let world = adminWorld()
            world.translocated = true
            world.original = folder.appendingPathComponent("Downloads/Test.app")
            let move = try offer(world)
            breakIt(world)
            XCTAssertThrowsError(try MoveToApplications.move(move, version: version, tools: tools(world)), name) { error in
                XCTAssertEqual(error as? MoveToApplications.Failure, expected, name)
            }
            XCTAssertEqual(bundleVersion(at: destination), "2.8.4cr", name)
            XCTAssertTrue(world.trashed.isEmpty, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: world.holders[0].path), name)
        }
    }

    /// The download is already where the copy goes: it is not thrown away.
    func testTheDownloadIsNeverTrashedWhenItIsTheDestination() throws {
        try FileManager.default.createDirectory(at: systemApplications, withIntermediateDirectories: true)
        try makeApp(at: running, version: version)
        let world = adminWorld()
        world.diskImage = nil
        world.translocated = true
        world.original = systemApplications.appendingPathComponent("Test.app")
        let move = try offer(world)
        _ = try MoveToApplications.move(move, version: version, tools: tools(world))
        XCTAssertTrue(world.trashed.isEmpty)
    }

    // MARK: - The quarantine mark

    func testTheQuarantineMarkIsRemovedThroughout() throws {
        let app = try makeApp(at: folder.appendingPathComponent("Marked.app"), version: version, quarantined: true)
        XCTAssertTrue(MoveToApplications.hasQuarantine(app))
        MoveToApplications.removeQuarantine(under: app)
        XCTAssertFalse(MoveToApplications.hasQuarantine(app))
        XCTAssertFalse(MoveToApplications.hasQuarantine(app.appendingPathComponent("Contents/MacOS/Test")))
        // Nothing to remove is fine.
        MoveToApplications.removeQuarantine(under: app)
    }

    /// The test host is not translocated; the look-up answers without crashing.
    func testTheTranslocationLookUpIsSafeOnACopyThatIsNot() {
        _ = MoveToApplications.originalLocation(ofTranslocated: Bundle.main.bundleURL)
    }
}
