import AppKit
import XCTest
@testable import DoublEnder

final class GuestUninstallTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuestUninstallTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Info.plist flag

    func testGuestSessionFlagParsing() {
        XCTAssertFalse(GuestUninstall.isGuestSession(info: nil))
        XCTAssertFalse(GuestUninstall.isGuestSession(info: [:]))
        XCTAssertFalse(GuestUninstall.isGuestSession(info: ["GuestSession": "NO"]))
        XCTAssertFalse(GuestUninstall.isGuestSession(info: ["GuestSession": "false"]))
        XCTAssertFalse(GuestUninstall.isGuestSession(info: ["GuestSession": "0"]))
        XCTAssertFalse(GuestUninstall.isGuestSession(info: ["GuestSession": false]))

        XCTAssertTrue(GuestUninstall.isGuestSession(info: ["GuestSession": "YES"]))
        XCTAssertTrue(GuestUninstall.isGuestSession(info: ["GuestSession": " yes \n"]))
        XCTAssertTrue(GuestUninstall.isGuestSession(info: ["GuestSession": "true"]))
        XCTAssertTrue(GuestUninstall.isGuestSession(info: ["GuestSession": "1"]))
        XCTAssertTrue(GuestUninstall.isGuestSession(info: ["GuestSession": true]))
    }

    // MARK: - When to offer at quit

    func testShouldOfferOnlyInGuestSessionWithCleanQuitAndNoPendingUploads() {
        XCTAssertTrue(GuestUninstall.shouldOffer(
            isGuestSession: true, forSystem: false, recorderOpen: true,
            hasUnuploadedTakes: false, alreadyOffered: false
        ))

        // Standard Host Cloud or Local build: never offers to uninstall.
        XCTAssertFalse(GuestUninstall.shouldOffer(
            isGuestSession: false, forSystem: false, recorderOpen: true,
            hasUnuploadedTakes: false
        ))

        // System logout / restart / shutdown: never holds up the system.
        XCTAssertFalse(GuestUninstall.shouldOffer(
            isGuestSession: true, forSystem: true, recorderOpen: true,
            hasUnuploadedTakes: false
        ))

        // No recorder window opened yet: nothing to ask.
        XCTAssertFalse(GuestUninstall.shouldOffer(
            isGuestSession: true, forSystem: false, recorderOpen: false,
            hasUnuploadedTakes: false
        ))

        // Pending uploads still on disk: keep the app and its defaults so the
        // next launch can finish uploading them.
        XCTAssertFalse(GuestUninstall.shouldOffer(
            isGuestSession: true, forSystem: false, recorderOpen: true,
            hasUnuploadedTakes: true
        ))

        // Never asks twice in the same quit.
        XCTAssertFalse(GuestUninstall.shouldOffer(
            isGuestSession: true, forSystem: false, recorderOpen: true,
            hasUnuploadedTakes: false, alreadyOffered: true
        ))
    }

    // MARK: - Origin detection

    private final class World {
        var translocated = false
        var original: URL?
        var diskImageVolume: URL?
        var diskImageFile: URL?
        var writableFolders: Set<String> = []
        var trashed: [URL] = []
        var detachedVolumes: [URL] = []
        var clearedDefaults = 0
        var openedURLs: [URL] = []

        var tools: GuestUninstall.Tools {
            GuestUninstall.Tools(
                isTranslocated: { _ in self.translocated },
                originalLocation: { _ in self.original },
                diskImageVolume: { _ in self.diskImageVolume },
                diskImageFile: { _ in self.diskImageFile },
                isWritableFolder: { self.writableFolders.contains($0.standardizedFileURL.path) },
                trash: { self.trashed.append($0) },
                detachVolumeAfterExit: { self.detachedVolumes.append($0) },
                clearDefaults: { self.clearedDefaults += 1 },
                openURL: { self.openedURLs.append($0) }
            )
        }
    }

    func testOriginDetectsInstalledTranslocatedAndDiskImage() {
        let app = URL(fileURLWithPath: "/Applications/DoublEnder Cloud.app")
        let world = World()
        XCTAssertEqual(GuestUninstall.origin(of: app, tools: world.tools), .installed(app: app))

        let downloaded = URL(fileURLWithPath: "/Users/guest/Downloads/DoublEnder Cloud.app")
        world.translocated = true
        world.original = downloaded
        XCTAssertEqual(GuestUninstall.origin(of: app, tools: world.tools), .translocated(original: downloaded))

        world.translocated = false
        let volume = URL(fileURLWithPath: "/Volumes/Install DoublEnder Cloud")
        let dmg = URL(fileURLWithPath: "/Users/guest/Downloads/DoublEnder-Cloud-Guest.dmg")
        world.diskImageVolume = volume
        world.diskImageFile = dmg
        // Backing DMG in a non-writable folder is not offered for trashing.
        XCTAssertEqual(GuestUninstall.origin(of: app, tools: world.tools),
                       .diskImage(volume: volume, imageFile: nil))

        // Backing DMG in a writable folder (e.g. ~/Downloads) is trashed too.
        world.writableFolders.insert("/Users/guest/Downloads")
        XCTAssertEqual(GuestUninstall.origin(of: app, tools: world.tools),
                       .diskImage(volume: volume, imageFile: dmg))
    }

    // MARK: - Alert choices & actions

    func testChoiceMappingFromAlertResponse() {
        XCTAssertEqual(GuestUninstall.choice(for: .alertFirstButtonReturn), .uninstall)
        XCTAssertEqual(GuestUninstall.choice(for: .alertSecondButtonReturn), .uninstallAndGetLocal)
        XCTAssertEqual(GuestUninstall.choice(for: .alertThirdButtonReturn), .keepAndQuit)
        XCTAssertEqual(GuestUninstall.choice(for: nil), .keepAndQuit)
    }

    func testKeepAndQuitTouchesNothing() {
        let world = World()
        let app = URL(fileURLWithPath: "/Applications/DoublEnder Cloud.app")
        let uninstalled = GuestUninstall.perform(.keepAndQuit, origin: .installed(app: app), tools: world.tools)
        XCTAssertFalse(uninstalled)
        XCTAssertTrue(world.trashed.isEmpty)
        XCTAssertTrue(world.detachedVolumes.isEmpty)
        XCTAssertEqual(world.clearedDefaults, 0)
        XCTAssertTrue(world.openedURLs.isEmpty)
    }

    func testUninstallInstalledAppTrashesBundleAndClearsDefaults() {
        let world = World()
        let app = URL(fileURLWithPath: "/Applications/DoublEnder Cloud.app")
        let uninstalled = GuestUninstall.perform(.uninstall, origin: .installed(app: app), tools: world.tools)
        XCTAssertTrue(uninstalled)
        XCTAssertEqual(world.trashed, [app])
        XCTAssertTrue(world.detachedVolumes.isEmpty)
        XCTAssertEqual(world.clearedDefaults, 1)
        XCTAssertTrue(world.openedURLs.isEmpty)
    }

    func testUninstallAndGetLocalOpensPublicPageAndTrashesOriginalTranslocatedApp() {
        let world = World()
        let downloaded = URL(fileURLWithPath: "/Users/guest/Downloads/DoublEnder Cloud.app")
        let uninstalled = GuestUninstall.perform(.uninstallAndGetLocal,
                                                 origin: .translocated(original: downloaded),
                                                 tools: world.tools)
        XCTAssertTrue(uninstalled)
        XCTAssertEqual(world.openedURLs, [GuestUninstall.publicRecorderURL])
        XCTAssertEqual(world.trashed, [downloaded])
        XCTAssertEqual(world.clearedDefaults, 1)
    }

    func testUninstallFromDiskImageTrashesDMGAndDetachesVolumeAfterExit() {
        let world = World()
        let volume = URL(fileURLWithPath: "/Volumes/Install DoublEnder Cloud")
        let dmg = URL(fileURLWithPath: "/Users/guest/Downloads/DoublEnder-Cloud-Guest.dmg")
        let uninstalled = GuestUninstall.perform(.uninstall,
                                                 origin: .diskImage(volume: volume, imageFile: dmg),
                                                 tools: world.tools)
        XCTAssertTrue(uninstalled)
        XCTAssertEqual(world.trashed, [dmg])
        XCTAssertEqual(world.detachedVolumes, [volume])
        XCTAssertEqual(world.clearedDefaults, 1)
    }

    func testExplanationDescribesOriginAndMentionsDesktopRecordingsAndFreeVersion() {
        let volume = URL(fileURLWithPath: "/Volumes/Install DoublEnder Cloud")
        let dmg = URL(fileURLWithPath: "/Users/guest/Downloads/DoublEnder-Cloud-Guest.dmg")
        let withDMG = GuestUninstall.explanation(for: .diskImage(volume: volume, imageFile: dmg),
                                                 appName: "DoublEnder Cloud")
        XCTAssertTrue(withDMG.contains("eject its disk image and move it to the Trash"))
        XCTAssertTrue(withDMG.contains("Your recordings on the Desktop are kept."))
        XCTAssertTrue(withDMG.contains("free local version"))

        let withoutDMG = GuestUninstall.explanation(for: .diskImage(volume: volume, imageFile: nil),
                                                    appName: "DoublEnder Cloud")
        XCTAssertTrue(withoutDMG.contains("eject its disk image."))

        let installed = GuestUninstall.explanation(
            for: .installed(app: URL(fileURLWithPath: "/Applications/DoublEnder Cloud.app")),
            appName: "DoublEnder Cloud"
        )
        XCTAssertTrue(installed.contains("move itself to the Trash"))
    }

    // MARK: - Parsing hdiutil info -plist

    func testDiskImageFileFindsMatchingMountedVolume() throws {
        let plist: [String: Any] = [
            "images": [
                [
                    "image-path": "/Users/guest/Downloads/Other.dmg",
                    "system-entities": [
                        ["dev-entry": "/dev/disk4s1", "mount-point": "/Volumes/Other"],
                    ],
                ],
                [
                    "image-path": "/Users/guest/Downloads/DoublEnder-Cloud-Guest.dmg",
                    "system-entities": [
                        ["dev-entry": "/dev/disk5"],
                        ["dev-entry": "/dev/disk5s1", "mount-point": "/Volumes/Install DoublEnder Cloud"],
                    ],
                ],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let match = GuestUninstall.diskImageFile(
            forVolume: URL(fileURLWithPath: "/Volumes/Install DoublEnder Cloud"),
            infoPlistData: data
        )
        XCTAssertEqual(match, URL(fileURLWithPath: "/Users/guest/Downloads/DoublEnder-Cloud-Guest.dmg"))

        let missing = GuestUninstall.diskImageFile(
            forVolume: URL(fileURLWithPath: "/Volumes/Unrelated"),
            infoPlistData: data
        )
        XCTAssertNil(missing)
    }

    // MARK: - Detach helper after process exit

    func testPrepareDetachWaitsForProcessExitThenDetachesVolume() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["0.2"]
        try sleeper.run()

        let log = folder.appendingPathComponent("detached.txt")
        let ejector = folder.appendingPathComponent("fake-hdiutil.sh")
        let script = """
            #!/bin/sh
            echo "$*" > "\(log.path)"
            """
        try Data(script.utf8).write(to: ejector)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ejector.path)

        let volume = URL(fileURLWithPath: "/Volumes/Install DoublEnder Cloud")
        let helper = try GuestUninstall.prepareDetach(volume: volume, after: sleeper.processIdentifier,
                                                      ejector: ejector.path)
        helper.waitUntilExit()
        XCTAssertEqual(helper.terminationStatus, 0)
        let recorded = try String(contentsOf: log, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(recorded, "detach /Volumes/Install DoublEnder Cloud -quiet")
    }
}
