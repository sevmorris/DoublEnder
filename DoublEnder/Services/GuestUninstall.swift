import AppKit

/// The Guest Cloud build: meant for a single recording session, with no move to
/// the Applications folder and no self-updates, and an offer to uninstall itself
/// and point to the free Local recorder when the guest quits.
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

    static let guestSessionKey = "GuestSession"
    static let publicRecorderURL = URL(string: "https://sevmorris.github.io/DoublEnder/")!

    /// True when the running bundle carries `GuestSession = YES` in its
    /// `Info.plist` (set via `GUEST_SESSION=YES` for `DoublEnder-Cloud-Guest.dmg`).
    static var isGuestSession: Bool {
        isGuestSession(info: Bundle.main.infoDictionary)
    }

    static func isGuestSession(info: [String: Any]?) -> Bool {
        if let flag = info?[guestSessionKey] as? Bool {
            return flag
        }
        guard let raw = info?[guestSessionKey] as? String else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes", "true", "1": return true
        default: return false
        }
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

    struct Tools {
        var isTranslocated: (URL) -> Bool
        var originalLocation: (URL) -> URL?
        var diskImageVolume: (URL) -> URL?
        var diskImageFile: (URL) -> URL?
        var isWritableFolder: (URL) -> Bool
        var trash: (URL) -> Void
        var detachVolumeAfterExit: (URL) -> Void
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

    /// The question's words.
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

    /// Carries out the guest's choice. Returns `true` when the app uninstalled
    /// itself (so termination cleanup knows not to write defaults back).
    @discardableResult
    static func perform(_ choice: Choice, origin: Origin, tools: Tools) -> Bool {
        guard choice != .keepAndQuit else { return false }
        if choice == .uninstallAndGetLocal {
            tools.openURL(publicRecorderURL)
        }
        switch origin {
        case .installed(let app):
            tools.trash(app)
        case .translocated(let original):
            if let original { tools.trash(original) }
        case .diskImage(let volume, let imageFile):
            if let imageFile { tools.trash(imageFile) }
            tools.detachVolumeAfterExit(volume)
        }
        tools.clearDefaults()
        return true
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
    static func live(bundleID: String, defaults: UserDefaults = .app) -> Self {
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
            trash: { try? fm.trashItem(at: $0, resultingItemURL: nil) },
            detachVolumeAfterExit: { volume in
                _ = try? GuestUninstall.prepareDetach(volume: volume)
            },
            clearDefaults: {
                guard !bundleID.isEmpty else { return }
                defaults.removePersistentDomain(forName: bundleID)
            },
            openURL: { NSWorkspace.shared.open($0) })
    }
}
