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

    // MARK: - Session mode persistence & upgrade inference

    func testStoredOrInferredModePromptsOnFreshFirstLaunchAndInfersHostOnExistingInstall() throws {
        let suiteName = folder.appendingPathComponent("defaults").path
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let apps = folder.appendingPathComponent("Applications", isDirectory: true)
        let dmgApp = folder.appendingPathComponent("Volumes/DoublEnder Cloud/DoublEnder Cloud.app")
        let installedApp = apps.appendingPathComponent("DoublEnder Cloud.app")

        // Brand-new launch from DMG or Applications with no prior history: nil so launch asks.
        XCTAssertNil(GuestUninstall.storedOrInferredMode(
            in: defaults, appURL: dmgApp, applicationsFolders: [apps], hasUpdateHistory: false
        ))
        XCTAssertNil(GuestUninstall.storedOrInferredMode(
            in: defaults, appURL: installedApp, applicationsFolders: [apps], hasUpdateHistory: false
        ))
        XCTAssertEqual(GuestUninstall.currentMode(in: defaults), .host)

        // An installed copy that has been through an update is a host's, even
        // with no guest name and no move to Applications.
        XCTAssertEqual(GuestUninstall.storedOrInferredMode(
            in: defaults, appURL: installedApp, applicationsFolders: [apps], hasUpdateHistory: true
        ), .host)
        defaults.removeObject(forKey: GuestUninstall.sessionModeKey)
        // ...but not a copy outside Applications.
        XCTAssertNil(GuestUninstall.storedOrInferredMode(
            in: defaults, appURL: dmgApp, applicationsFolders: [apps], hasUpdateHistory: true
        ))

        // Existing host upgrading in /Applications (has lastGuestName from an earlier version):
        // inferred and persisted as .host without asking.
        defaults.set("Seven", forKey: "lastGuestName")
        XCTAssertEqual(GuestUninstall.storedOrInferredMode(
            in: defaults, appURL: installedApp, applicationsFolders: [apps]
        ), .host)
        XCTAssertEqual(GuestUninstall.currentMode(in: defaults), .host)

        // Switching to .guest in Settings persists .guest.
        GuestUninstall.setMode(.guest, in: defaults)
        XCTAssertEqual(GuestUninstall.currentMode(in: defaults), .guest)
        XCTAssertEqual(GuestUninstall.storedOrInferredMode(
            in: defaults, appURL: installedApp, applicationsFolders: [apps]
        ), .guest)
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
        /// Items whose trash fails.
        var stuck: Set<URL> = []
        var detachedVolumes: [URL] = []
        var otherCopy = false
        var trashedSupportFolder = 0
        var clearedDefaults = 0
        var openedURLs: [URL] = []

        var tools: GuestUninstall.Tools {
            GuestUninstall.Tools(
                isTranslocated: { _ in self.translocated },
                originalLocation: { _ in self.original },
                diskImageVolume: { _ in self.diskImageVolume },
                diskImageFile: { _ in self.diskImageFile },
                isWritableFolder: { self.writableFolders.contains($0.standardizedFileURL.path) },
                trash: { url in
                    guard !self.stuck.contains(url) else { return false }
                    self.trashed.append(url)
                    return true
                },
                detachVolumeAfterExit: { self.detachedVolumes.append($0) },
                otherCopyInstalled: { self.otherCopy },
                trashSupportFolder: { self.trashedSupportFolder += 1 },
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
        let outcome = GuestUninstall.perform(.keepAndQuit, origin: .installed(app: app), tools: world.tools)
        XCTAssertEqual(outcome, .kept)
        XCTAssertEqual(world.trashedSupportFolder, 0)
        XCTAssertTrue(world.trashed.isEmpty)
        XCTAssertTrue(world.detachedVolumes.isEmpty)
        XCTAssertEqual(world.clearedDefaults, 0)
        XCTAssertTrue(world.openedURLs.isEmpty)
    }

    func testUninstallInstalledAppTrashesBundleAndClearsDefaults() {
        let world = World()
        let app = URL(fileURLWithPath: "/Applications/DoublEnder Cloud.app")
        let outcome = GuestUninstall.perform(.uninstall, origin: .installed(app: app), tools: world.tools)
        XCTAssertEqual(outcome, .removed(clearedSettings: true))
        XCTAssertEqual(world.trashed, [app])
        XCTAssertEqual(world.trashedSupportFolder, 1)
        XCTAssertTrue(world.detachedVolumes.isEmpty)
        XCTAssertEqual(world.clearedDefaults, 1)
        XCTAssertTrue(world.openedURLs.isEmpty)
    }

    func testUninstallAndGetLocalOpensPublicPageAndTrashesOriginalTranslocatedApp() {
        let world = World()
        let downloaded = URL(fileURLWithPath: "/Users/guest/Downloads/DoublEnder Cloud.app")
        let outcome = GuestUninstall.perform(.uninstallAndGetLocal,
                                             origin: .translocated(original: downloaded),
                                             tools: world.tools)
        XCTAssertEqual(outcome, .removed(clearedSettings: true))
        XCTAssertEqual(world.openedURLs, [GuestUninstall.publicRecorderURL])
        XCTAssertEqual(world.trashed, [downloaded])
        XCTAssertEqual(world.clearedDefaults, 1)
    }

    func testUninstallFromDiskImageTrashesDMGAndDetachesVolumeAfterExit() {
        let world = World()
        let volume = URL(fileURLWithPath: "/Volumes/Install DoublEnder Cloud")
        let dmg = URL(fileURLWithPath: "/Users/guest/Downloads/DoublEnder-Cloud-Guest.dmg")
        let outcome = GuestUninstall.perform(.uninstall,
                                             origin: .diskImage(volume: volume, imageFile: dmg),
                                             tools: world.tools)
        XCTAssertEqual(outcome, .removed(clearedSettings: true))
        XCTAssertEqual(world.trashed, [dmg])
        XCTAssertEqual(world.detachedVolumes, [volume])
        XCTAssertEqual(world.clearedDefaults, 1)
    }

    /// A trash that fails is reported, and nothing else is changed: the
    /// settings stay, so the next launch is the same copy, not a new one.
    func testAFailedTrashIsReportedAndKeepsTheSettings() {
        let world = World()
        let app = URL(fileURLWithPath: "/Applications/DoublEnder Cloud.app")
        world.stuck = [app]
        XCTAssertEqual(GuestUninstall.perform(.uninstall, origin: .installed(app: app), tools: world.tools),
                       .notRemoved(app))
        XCTAssertTrue(world.trashed.isEmpty)
        XCTAssertEqual(world.clearedDefaults, 0)
        XCTAssertEqual(world.trashedSupportFolder, 0)
        XCTAssertTrue(GuestUninstall.notRemovedMessage(for: app).contains("DoublEnder Cloud.app"))
    }

    /// A disk image whose file cannot go is still ejected after the exit.
    func testADiskImageThatCannotBeTrashedIsStillEjected() {
        let world = World()
        let volume = URL(fileURLWithPath: "/Volumes/Install DoublEnder Cloud")
        let dmg = URL(fileURLWithPath: "/Users/guest/Downloads/DoublEnder-Cloud-Guest.dmg")
        world.stuck = [dmg]
        XCTAssertEqual(GuestUninstall.perform(.uninstall, origin: .diskImage(volume: volume, imageFile: dmg),
                                              tools: world.tools),
                       .notRemoved(dmg))
        XCTAssertEqual(world.detachedVolumes, [volume])
        XCTAssertEqual(world.clearedDefaults, 0)
    }

    /// Another installed copy shares the settings and the support folder:
    /// uninstalling this one leaves them for it.
    func testAnotherInstalledCopyKeepsTheSharedSettings() {
        let world = World()
        world.otherCopy = true
        let downloaded = URL(fileURLWithPath: "/Users/guest/Downloads/DoublEnder Cloud.app")
        XCTAssertEqual(GuestUninstall.perform(.uninstall, origin: .installed(app: downloaded), tools: world.tools),
                       .removed(clearedSettings: false))
        XCTAssertEqual(world.trashed, [downloaded])
        XCTAssertEqual(world.clearedDefaults, 0)
        XCTAssertEqual(world.trashedSupportFolder, 0)
    }

    /// The live check finds a copy of this app in an Applications folder, and
    /// not one of another app with the same name.
    func testTheLiveCheckFindsAnInstalledCopyByBundleID() throws {
        let apps = folder.appendingPathComponent("Applications", isDirectory: true)
        let copy = apps.appendingPathComponent("DoublEnder Cloud.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let tools = { (bundleID: String) in
            GuestUninstall.Tools.live(bundleID: bundleID, applicationsFolders: [apps],
                                      appName: "DoublEnder Cloud.app",
                                      supportFolder: self.folder.appendingPathComponent("Support"))
        }
        XCTAssertFalse(tools("io.github.sevmorris.DoublEnderCloud").otherCopyInstalled(), "no Info.plist yet")
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "io.github.sevmorris.DoublEnderCloud",
                               "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        try plist.write(to: copy.appendingPathComponent("Info.plist"))
        XCTAssertTrue(tools("io.github.sevmorris.DoublEnderCloud").otherCopyInstalled())
        XCTAssertFalse(tools("io.github.sevmorris.SomethingElse").otherCopyInstalled())
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
