import AppKit
import SwiftUI

/// How this copy of DoublEnder Cloud is used:
///   - `.host`: permanent installation for a regular host; moves to the
///     Applications folder and keeps itself up to date automatically.
///   - `.guest`: temporary session for a one-time guest; runs from where it is
///     and installs no update by itself, but says when a newer version is out
///     (the menu's check, silent, at launch), and offers to uninstall itself
///     and point to the free Local recorder when quitting.
enum CloudSessionMode: String, CaseIterable, Identifiable, Equatable {
    case host
    case guest

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .host: return "Regular Host (Keep & auto-update)"
        case .guest: return "One-Time Guest (Offer to uninstall at quit)"
        }
    }
}

/// First-launch mode selection (`CloudSessionMode`) and the Guest mode's
/// self-uninstall flow at quit.
///
/// Nothing here may trap a guest in the app when they ask to quit, or strand a
/// recording that still needs to upload:
///   - A logout, restart or shutdown quits at once without asking.
///   - While any recording is still waiting on disk to be uploaded, the app
///     quits without offering to uninstall, so the next launch can still upload
///     it and the pending-upload list in defaults is kept.
///   - Moving the app to the Trash happens in this process before it exits,
///     where macOS holds the app responsible for its own bundle; when the app
///     is running from a mounted disk image, a small `sh` process detaches the
///     volume once this process has gone, as `UpdateRelauncher` does.
///   - Recordings on the Desktop are never touched.
enum GuestUninstall {

    static let sessionModeKey = "cloudSessionMode"

    /// The Applications folders a copy is installed in.
    static var applicationsFolders: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    }
    static let publicRecorderURL = URL(string: "https://sevmorris.github.io/DoublEnder/")!

    /// True when the user has selected One-Time Guest mode. Reads `UserDefaults.app`
    /// directly so checking it at launch or quit never instantiates `RecorderViewModel`.
    static var isGuestSession: Bool {
        currentMode(in: .app) == .guest
    }

    /// The active mode, defaulting to `.host` when none has been stored yet.
    static func currentMode(in defaults: UserDefaults = .app) -> CloudSessionMode {
        guard let raw = defaults.string(forKey: sessionModeKey),
              let mode = CloudSessionMode(rawValue: raw) else {
            return .host
        }
        return mode
    }

    static func setMode(_ mode: CloudSessionMode, in defaults: UserDefaults = .app) {
        defaults.set(mode.rawValue, forKey: sessionModeKey)
    }

    /// The mode already chosen on an earlier launch, or `.host` inferred for an
    /// existing host upgrading from a version before `cloudSessionMode` existed,
    /// or `nil` on a brand-new first run so the launch flow asks once.
    ///
    /// Prior history is a move to Applications, a guest name, or an update
    /// this copy has been through (`hasUpdateHistory`, the update state on
    /// disk). Until 2026-11-19 only the first two counted, so a host who had
    /// put the app in Applications by hand and never typed a name was asked
    /// after upgrading, as if new.
    static func storedOrInferredMode(in defaults: UserDefaults = .app,
                                     appURL: URL = Bundle.main.bundleURL,
                                     applicationsFolders: [URL] = GuestUninstall.applicationsFolders,
                                     hasUpdateHistory: Bool = FileManager.default.fileExists(
                                         atPath: UpdateStateStore.app.url.path)) -> CloudSessionMode? {
        if let raw = defaults.string(forKey: sessionModeKey),
           let mode = CloudSessionMode(rawValue: raw) {
            return mode
        }
        let appDir = appURL.deletingLastPathComponent().standardizedFileURL.path
        let inApplications = applicationsFolders.contains {
            $0.standardizedFileURL.path == appDir
        }
        let hasPriorHistory = defaults.object(forKey: MoveToApplications.lastMoveKey) != nil
            || !(defaults.string(forKey: "lastGuestName") ?? "").isEmpty
            || hasUpdateHistory
        if inApplications && hasPriorHistory {
            setMode(.host, in: defaults)
            return .host
        }
        return nil
    }

    /// Words for the first-launch Host vs. Guest setup card.
    static func firstLaunchHostDescription(appName: String, willMoveToApplications: Bool) -> String {
        if willMoveToApplications {
            return "Moves \(appName) to your Applications folder, ejects the disk image, and keeps itself up to date."
        }
        return "Keeps \(appName) installed and automatically up to date."
    }

    static func firstLaunchGuestDescription() -> String {
        "Opens the recorder right away for this session without installing, and offers to remove itself when you quit."
    }

    /// Where the running copy is, which decides the words and what is removed.
    enum Origin: Equatable {
        /// Running directly from a mounted disk image. `imageFile` is the
        /// backing `.dmg` file when it lives in a writable folder, moved to the
        /// Trash before the volume is detached after exit.
        case diskImage(volume: URL, imageFile: URL?)
        /// Running from Gatekeeper's read-only translocation mount. `original`
        /// is the downloaded `.app` bundle, moved to the Trash; macOS unmounts
        /// the translocation copy when the process exits.
        case translocated(original: URL?)
        /// Running from a folder on disk (`Downloads`, `Applications`, `Desktop`).
        case installed(app: URL)
    }

    enum Choice: Equatable {
        case uninstall
        case uninstallAndGetLocal
        case keepAndQuit
    }

    /// What `perform` did.
    enum Outcome: Equatable {
        /// Keep & Quit: nothing touched.
        case kept
        /// The app (or its disk image) is in the Trash. `clearedSettings` is
        /// false when another installed copy shares the settings and the
        /// Application Support folder, which then stay.
        case removed(clearedSettings: Bool)
        /// The item at this URL could not be moved to the Trash (a copy in
        /// /Applications on a standard account, say), so it is still there,
        /// and the settings are kept. The guest is told.
        case notRemoved(URL)
    }

    struct Tools {
        var isTranslocated: (URL) -> Bool
        var originalLocation: (URL) -> URL?
        var diskImageVolume: (URL) -> URL?
        var diskImageFile: (URL) -> URL?
        var isWritableFolder: (URL) -> Bool
        /// False when the item could not be moved to the Trash.
        var trash: (URL) -> Bool
        var detachVolumeAfterExit: (URL) -> Void
        /// Another copy of this app installed in an Applications folder, which
        /// shares this one's settings and Application Support folder.
        var otherCopyInstalled: () -> Bool
        /// Moves this app's Application Support folder (the update state, and
        /// any version kept for going back) to the Trash.
        var trashSupportFolder: () -> Void
        var clearDefaults: () -> Void
        var openURL: (URL) -> Void
    }

    // MARK: - Deciding

    /// Whether a quit should offer to uninstall the app.
    static func shouldOffer(isGuestSession: Bool, forSystem: Bool, recorderOpen: Bool,
                            hasUnuploadedTakes: Bool, alreadyOffered: Bool = false) -> Bool {
        isGuestSession && !forSystem && recorderOpen && !hasUnuploadedTakes && !alreadyOffered
    }

    static func origin(of app: URL, tools: Tools) -> Origin {
        if tools.isTranslocated(app) {
            return .translocated(original: tools.originalLocation(app))
        }
        if let volume = tools.diskImageVolume(app) {
            let imageFile = tools.diskImageFile(volume).flatMap { file in
                tools.isWritableFolder(file.deletingLastPathComponent()) ? file : nil
            }
            return .diskImage(volume: volume, imageFile: imageFile)
        }
        return .installed(app: app)
    }

    /// The quit question's words.
    static func explanation(for origin: Origin, appName: String) -> String {
        let action: String
        switch origin {
        case .diskImage(_, let imageFile?):
            _ = imageFile
            action = "If you're finished with your session, \(appName) can eject its disk image and move it to the Trash."
        case .diskImage(_, nil):
            action = "If you're finished with your session, \(appName) can eject its disk image."
        case .translocated, .installed:
            action = "If you're finished with your session, \(appName) can move itself to the Trash."
        }
        return "\(action) Your recordings on the Desktop are kept.\n\n"
            + "If you'd like to use DoublEnder for your own recordings, you can get the free local version."
    }

    /// `response` is nil when the question could not open: the quit goes ahead
    /// without removing anything.
    static func choice(for response: NSApplication.ModalResponse?) -> Choice {
        switch response {
        case .alertFirstButtonReturn?:
            return .uninstall
        case .alertSecondButtonReturn?:
            return .uninstallAndGetLocal
        default:
            return .keepAndQuit
        }
    }

    // MARK: - Uninstalling

    /// Carries out the guest's choice.
    ///
    /// The settings and the Application Support folder go only once the app
    /// is in the Trash, and only when no other installed copy shares them.
    /// Until 2026-11-19 a trash that failed went unnoticed: the settings were
    /// wiped and the app quit, so the guest believed it was gone, and the next
    /// launch asked Host or Guest again. The support folder was never removed.
    @discardableResult
    static func perform(_ choice: Choice, origin: Origin, tools: Tools) -> Outcome {
        guard choice != .keepAndQuit else { return .kept }
        if choice == .uninstallAndGetLocal {
            tools.openURL(publicRecorderURL)
        }
        switch origin {
        case .installed(let app):
            guard tools.trash(app) else { return .notRemoved(app) }
        case .translocated(let original):
            if let original, !tools.trash(original) { return .notRemoved(original) }
        case .diskImage(let volume, let imageFile):
            // The volume is ejected after the exit whether or not its image
            // file can go: the app on it is not run again from there.
            tools.detachVolumeAfterExit(volume)
            if let imageFile, !tools.trash(imageFile) { return .notRemoved(imageFile) }
        }
        // Asked after the trash, so this copy, if it was in Applications, is
        // gone and not counted.
        guard !tools.otherCopyInstalled() else { return .removed(clearedSettings: false) }
        tools.trashSupportFolder()
        tools.clearDefaults()
        return .removed(clearedSettings: true)
    }

    /// The words when the trash failed.
    static func notRemovedMessage(for item: URL) -> String {
        "\u{201C}\(item.lastPathComponent)\u{201D} couldn't be moved to the Trash, so it's still where it was. "
            + "You can drag it to the Trash yourself; your Mac may ask for an administrator's password. "
            + "Your recordings on the Desktop are kept."
    }

    // MARK: - Backing disk image

    /// Finds the `.dmg` file backing a mounted volume `/Volumes/...` in the
    /// plist output of `hdiutil info -plist`.
    static func diskImageFile(forVolume volume: URL, infoPlistData: Data) -> URL? {
        guard let root = try? PropertyListSerialization.propertyList(from: infoPlistData, format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return nil }
        let targetMount = volume.standardizedFileURL.path
        for image in images {
            guard let imagePath = image["image-path"] as? String, !imagePath.isEmpty,
                  let entities = image["system-entities"] as? [[String: Any]] else { continue }
            let matchesVolume = entities.contains { entity in
                guard let mountPoint = entity["mount-point"] as? String else { return false }
                return URL(fileURLWithPath: mountPoint).standardizedFileURL.path == targetMount
            }
            if matchesVolume {
                return URL(fileURLWithPath: imagePath)
            }
        }
        return nil
    }

    /// $1: PID to wait for. $2: the volume to eject once the process has gone.
    /// $3: the ejector, `/usr/bin/hdiutil` outside of tests.
    static let detachScript = """
        pid="$1"; volume="$2"; ejector="$3"
        i=0
        while kill -0 "$pid" 2>/dev/null; do
            i=$((i + 1))
            [ "$i" -eq 50 ] && kill -KILL "$pid" 2>/dev/null
            [ "$i" -gt 150 ] && exit 1
            sleep 0.2
        done
        "$ejector" detach "$volume" -quiet
        """

    @discardableResult
    static func prepareDetach(volume: URL, after pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                              ejector: String = "/usr/bin/hdiutil") throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", detachScript, "sh", String(pid), volume.path, ejector]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}

// MARK: - The real thing

extension GuestUninstall.Tools {
    static func live(bundleID: String, defaults: UserDefaults = .app,
                     applicationsFolders: [URL] = GuestUninstall.applicationsFolders,
                     appName: String = Bundle.main.bundleURL.lastPathComponent,
                     supportFolder: URL = UpdateStateStore.app.url.deletingLastPathComponent()) -> Self {
        let fm = FileManager.default
        return Self(
            isTranslocated: { SelfUpdater.isTranslocated($0) },
            originalLocation: { MoveToApplications.originalLocation(ofTranslocated: $0) },
            diskImageVolume: { app in
                guard let values = try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeURLKey]),
                      values.volumeIsReadOnly == true, let volume = values.volume,
                      volume.path.hasPrefix("/Volumes/") else { return nil }
                return volume
            },
            diskImageFile: { volume in
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                process.arguments = ["info", "-plist"]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    return nil
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                return GuestUninstall.diskImageFile(forVolume: volume, infoPlistData: data)
            },
            isWritableFolder: { fm.isWritableFile(atPath: $0.path) },
            trash: { (try? fm.trashItem(at: $0, resultingItemURL: nil)) != nil },
            detachVolumeAfterExit: { volume in
                _ = try? GuestUninstall.prepareDetach(volume: volume)
            },
            otherCopyInstalled: {
                applicationsFolders.contains { folder in
                    let copy = folder.appendingPathComponent(appName)
                    // The plist itself, not Bundle(url:), which keeps the
                    // first answer for a path for as long as the app runs.
                    let plist = copy.appendingPathComponent("Contents/Info.plist")
                    guard let info = NSDictionary(contentsOf: plist) else { return false }
                    return info["CFBundleIdentifier"] as? String == bundleID
                }
            },
            trashSupportFolder: {
                guard fm.fileExists(atPath: supportFolder.path) else { return }
                _ = try? fm.trashItem(at: supportFolder, resultingItemURL: nil)
            },
            clearDefaults: {
                guard !bundleID.isEmpty else { return }
                defaults.removePersistentDomain(forName: bundleID)
            },
            openURL: { NSWorkspace.shared.open($0) })
    }
}

// MARK: - Themed First-Launch Setup / Installer Window

private let setupBg        = Color(red: 0x0D/255, green: 0x08/255, blue: 0x00/255)
private let setupBorder    = Color(red: 0xFF/255, green: 0xB3/255, blue: 0x47/255).opacity(0.45)
private let setupAmber     = Color(red: 0xFF/255, green: 0xD5/255, blue: 0x80/255)
private let setupIcon      = Color(red: 0xF5/255, green: 0xA6/255, blue: 0x23/255)
private let setupBodyText  = Color(red: 0xF0/255, green: 0xE0/255, blue: 0xC0/255)
private let setupMutedText = Color(red: 0xE8/255, green: 0xD8/255, blue: 0xC0/255).opacity(0.60)
private let setupFieldBg   = Color(red: 0x1A/255, green: 0x0A/255, blue: 0x00/255)

struct CloudSetupView: View {
    let appName: String
    let willMoveToApplications: Bool
    let onChoose: (CloudSessionMode) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(setupIcon)
                .shadow(color: setupIcon.opacity(0.60), radius: 8)

            Text(appName.uppercased())
                .font(.system(size: 12, weight: .bold))
                .tracking(1.8)
                .foregroundColor(setupAmber)
                .shadow(color: setupIcon.opacity(0.85), radius: 6)

            Text("How are you using \(appName)?")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(setupBodyText)

            VStack(spacing: 10) {
                choiceButton(
                    title: "RUN AS GUEST — ONE SESSION",
                    subtitle: GuestUninstall.firstLaunchGuestDescription(),
                    action: { onChoose(.guest) }
                )
                choiceButton(
                    title: willMoveToApplications
                        ? "INSTALL AS HOST — KEEP & UPDATE"
                        : "USE AS HOST — KEEP & UPDATE",
                    subtitle: GuestUninstall.firstLaunchHostDescription(
                        appName: appName,
                        willMoveToApplications: willMoveToApplications
                    ),
                    action: { onChoose(.host) }
                )
            }
            .padding(.top, 2)

            Text("You can switch between Host and Guest anytime in Settings.")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(setupMutedText)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(width: 400)
        .background(WindowDragArea())
        .background(setupBg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(setupBorder, lineWidth: 1.5)
        )
        .shadow(color: Color(red: 0xC9/255, green: 0x6A/255, blue: 0x00/255).opacity(0.30), radius: 20)
        .preferredColorScheme(.dark)
    }

    private func choiceButton(title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.4)
                    .foregroundColor(setupIcon)
                Text(subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(setupBodyText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 6).fill(setupFieldBg))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(setupIcon, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

@MainActor
enum CloudSetupPrompt {
    static func present(appName: String, willMoveToApplications: Bool) -> CloudSessionMode {
        var selected: CloudSessionMode = .guest
        let window = UploadConfirmationWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = CloudSetupView(
            appName: appName,
            willMoveToApplications: willMoveToApplications
        ) { [weak window] mode in
            selected = mode
            NSApp.stopModal()
            window?.orderOut(nil)
        }
        window.contentViewController = NSHostingController(rootView: view)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .modalPanel
        if let content = window.contentViewController?.view {
            window.setContentSize(content.fittingSize)
        }
        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let wf = window.frame
            window.setFrameOrigin(NSPoint(x: sf.midX - wf.width / 2, y: sf.midY - wf.height / 2))
        } else {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.runModal(for: window)
        return selected
    }
}
