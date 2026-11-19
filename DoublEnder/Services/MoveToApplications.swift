import AppKit

/// Moves a copy of the app that cannot keep itself up to date into the
/// Applications folder, where it can.
///
/// A guest who opens the app straight from its disk image, or from Downloads
/// where Gatekeeper runs it from a read-only copy of its own (App
/// Translocation), has a copy that can never replace itself. The update at
/// launch passes it by, and every launch with a newer version out told them to
/// move it to Applications and offered a download, which they would open from
/// the disk image again. Nothing changed until they did something they were
/// never going to do. This asks once per launch, with one button, and does it.
///
/// The steps, none of which touches the copy that is running:
///   1. Copy the app into a folder on the Applications folder's volume.
///   2. Remove the quarantine mark from the copy. It is a copy of the app that
///      is running, which Gatekeeper has already let open; with the mark it
///      would be translocated again, and be no better off.
///   3. Check the copy: a signed release of this app, at this version.
///   4. Put it in place: beside nothing, or exchanged in one step with an older
///      copy that was there.
///   5. Put the downloaded original in the Trash, so there is one copy.
///   6. Open the new copy once this one has quit, and eject the disk image.
///
/// If a copy as new as this one is already in Applications, nothing is copied:
/// that one is opened instead, without asking. It is the same app.
///
/// Nothing here may keep a guest from recording: any failure leaves the
/// running copy as it was, and the app opens as usual.
enum MoveToApplications {

    /// Where the running copy is, which decides the words and what is cleaned up.
    enum Origin: Equatable {
        /// On a disk image, which is ejected afterwards.
        case diskImage(volume: URL)
        /// Translocated by Gatekeeper. `original` is where the download is, when
        /// macOS says; it goes to the Trash afterwards.
        case downloaded(original: URL?)
        /// Somewhere else that cannot exchange two items in one step (a network
        /// share, an exFAT disk). Left where it is.
        case elsewhere
    }

    struct Offer: Equatable {
        var appName: String
        var source: URL
        var destination: URL
        /// An older copy of this app is at `destination`, and is replaced.
        var replacing: Bool
        var origin: Origin
    }

    enum Decision: Equatable {
        /// Nothing to do: the app opens as usual.
        case stay
        /// A copy at least as new is already installed: open it.
        case openInstalled(URL, ejecting: URL?)
        /// Ask, and move if the answer is yes.
        case offer(Offer)
    }

    enum Failure: LocalizedError, Equatable {
        case copy
        case quarantine
        case notVerified
        case install(String)
        case relaunch(String)

        var errorDescription: String? {
            switch self {
            case .copy:
                return "The app couldn't be copied to the Applications folder."
            case .quarantine:
                return "macOS kept its download mark on the copy."
            case .notVerified:
                return "The copy didn't match the app."
            case .install(let reason):
                return "The copy couldn't be put in place (\(reason))."
            case .relaunch(let reason):
                return "The app couldn't arrange to reopen itself (\(reason))."
            }
        }
    }

    /// Two minutes: a move whose new copy somehow came up stuck as well does
    /// not hand over again and again.
    static let retryAfter: TimeInterval = 120
    static let lastMoveKey = "lastMoveToApplications"

    /// What `decide` and `move` need of the world.
    struct Tools {
        /// True when this copy is a signed release in a place it cannot update
        /// itself from (`SelfUpdater.Obstacle.readOnlyLocation`).
        var isStuck: (URL) -> Bool
        var isTranslocated: (URL) -> Bool
        /// The read-only volume holding a copy, when that volume is a mounted
        /// disk image. Asked of the running copy, or of a translocated copy's
        /// original.
        var diskImageVolume: (URL) -> URL?
        /// Where a translocated copy was downloaded to.
        var originalLocation: (URL) -> URL?
        /// A signed release of this app.
        var isRelease: (URL) -> Bool
        var version: (URL) -> String?
        var exists: (URL) -> Bool
        var isWritableFolder: (URL) -> Bool
        var applicationsFolders: [URL]
        var makeFolder: (URL) throws -> Void
        /// A new, empty folder on the same volume as the one given.
        var makeHolder: (URL) throws -> URL
        var copy: (_ from: URL, _ to: URL) throws -> Void
        var removeQuarantine: (URL) -> Void
        var hasQuarantine: (URL) -> Bool
        var swap: (_ staged: URL, _ installed: URL) throws -> Void
        var moveItem: (_ from: URL, _ to: URL) throws -> Void
        var removeItem: (URL) -> Void
        var trash: (URL) -> Void
    }

    // MARK: - Deciding

    static func decide(app: URL, appName: String, version: String, lastMove: Date?, now: Date = Date(),
                       tools: Tools) -> Decision {
        guard tools.isStuck(app) else { return .stay }
        if let lastMove, now.timeIntervalSince(lastMove) < retryAfter { return .stay }

        // A copy translocated from a disk image is on the disk image: macOS
        // translocates an app opened from a quarantined image too. Until
        // 2026-11-19 it counted as downloaded, so the question said it ran
        // from the folder it was downloaded to, the move tried to trash the
        // original on the read-only volume, and the image stayed mounted.
        let origin: Origin
        if tools.isTranslocated(app) {
            let original = tools.originalLocation(app)
            if let original, let volume = tools.diskImageVolume(original) {
                origin = .diskImage(volume: volume)
            } else {
                origin = .downloaded(original: original)
            }
        } else if let volume = tools.diskImageVolume(app) {
            origin = .diskImage(volume: volume)
        } else {
            origin = .elsewhere
        }

        let name = app.lastPathComponent
        // A copy at least as new already installed: that is the one to run.
        for folder in tools.applicationsFolders {
            let installed = folder.appendingPathComponent(name)
            guard tools.exists(installed), tools.isRelease(installed),
                  let installedVersion = tools.version(installed),
                  !isOlder(installedVersion, than: version) else { continue }
            return .openInstalled(installed, ejecting: origin.volumeToEject)
        }

        // The first Applications folder this user can write to: /Applications
        // for an administrator, their own otherwise. A folder that does not
        // exist yet counts when its parent can take it.
        guard let folder = tools.applicationsFolders.first(where: {
            tools.exists($0) ? tools.isWritableFolder($0) : tools.isWritableFolder($0.deletingLastPathComponent())
        }) else { return .stay }
        let destination = folder.appendingPathComponent(name)
        var replacing = false
        if tools.exists(destination) {
            // Something there that is not an older release of this app (a
            // development build, someone else's file) is left alone.
            guard tools.isRelease(destination), let there = tools.version(destination),
                  isOlder(there, than: version) else { return .stay }
            replacing = true
        }
        return .offer(Offer(appName: appName, source: app, destination: destination,
                            replacing: replacing, origin: origin))
    }

    static func isOlder(_ version: String, than other: String) -> Bool {
        SelfUpdater.numericVersion(version)
            .compare(SelfUpdater.numericVersion(other), options: .numeric) == .orderedAscending
    }

    // MARK: - Asking

    /// The question's words.
    static func explanation(for offer: Offer) -> String {
        let whereItIs: String
        switch offer.origin {
        case .diskImage:
            whereItIs = "\(offer.appName) is running from its disk image"
        case .downloaded:
            whereItIs = "\(offer.appName) is running from the folder it was downloaded to"
        case .elsewhere:
            whereItIs = "\(offer.appName) is on a disk"
        }
        var text = "\(whereItIs), where it can't keep itself up to date. In your Applications folder it updates by itself."
        if offer.replacing {
            text += " The older copy there is replaced."
        }
        return text
    }

    // MARK: - Moving

    /// Puts a checked copy at `offer.destination` and returns it. Blocks while
    /// it copies; run it off the main thread. On any failure the running copy,
    /// and whatever was at the destination, are as they were.
    static func move(_ offer: Offer, version: String, tools: Tools) throws -> URL {
        let folder = offer.destination.deletingLastPathComponent()
        if !tools.exists(folder) {
            do {
                try tools.makeFolder(folder)
            } catch {
                throw Failure.install(error.localizedDescription)
            }
        }
        let holder: URL
        do {
            holder = try tools.makeHolder(folder)
        } catch {
            throw Failure.install(error.localizedDescription)
        }
        // Whatever happens, the holder goes: before the install it holds the
        // copy, after an exchange the older version.
        defer { tools.removeItem(holder) }

        let staged = holder.appendingPathComponent(offer.destination.lastPathComponent)
        do {
            try tools.copy(offer.source, staged)
        } catch {
            throw Failure.copy
        }
        tools.removeQuarantine(staged)
        guard !tools.hasQuarantine(staged) else { throw Failure.quarantine }
        guard tools.isRelease(staged), tools.version(staged) == version else { throw Failure.notVerified }

        do {
            if offer.replacing {
                try tools.swap(staged, offer.destination)
            } else {
                try tools.moveItem(staged, offer.destination)
            }
        } catch {
            throw Failure.install(error.localizedDescription)
        }

        if case .downloaded(let original?) = offer.origin,
           original.standardizedFileURL != offer.destination.standardizedFileURL {
            tools.trash(original)
        }
        return offer.destination
    }
}

extension MoveToApplications.Origin {
    var volumeToEject: URL? {
        if case .diskImage(let volume) = self { return volume }
        return nil
    }
}

// MARK: - The real thing

extension MoveToApplications.Tools {
    static func live(bundleID: String) -> Self {
        let requirement = SelfUpdater.appRequirement(bundleID: bundleID)
        let fm = FileManager.default
        return Self(
            isStuck: { SelfUpdater.obstacle(for: $0, requirement: requirement) == .readOnlyLocation },
            isTranslocated: { SelfUpdater.isTranslocated($0) },
            diskImageVolume: { app in
                guard let values = try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeURLKey]),
                      values.volumeIsReadOnly == true, let volume = values.volume,
                      volume.path.hasPrefix("/Volumes/") else { return nil }
                return volume
            },
            originalLocation: { MoveToApplications.originalLocation(ofTranslocated: $0) },
            isRelease: { app in
                Bundle(url: app)?.bundleIdentifier == bundleID && SelfUpdater.isSigned(app, requirement: requirement)
            },
            version: { bundleVersion(at: $0) },
            exists: { fm.fileExists(atPath: $0.path) },
            isWritableFolder: { fm.isWritableFile(atPath: $0.path) },
            applicationsFolders: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            ],
            makeFolder: { try fm.createDirectory(at: $0, withIntermediateDirectories: true) },
            makeHolder: { try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: $0, create: true) },
            copy: { from, to in
                // ditto keeps the signature, the resource forks and every
                // attribute; the copy is checked afterwards either way.
                guard SelfUpdater.runTool("/usr/bin/ditto", [from.path, to.path], deadline: 120,
                                          isCancelled: { false }) == .success else { throw MoveToApplications.Failure.copy }
            },
            removeQuarantine: { MoveToApplications.removeQuarantine(under: $0) },
            hasQuarantine: { MoveToApplications.hasQuarantine($0) },
            swap: { try SelfUpdater.swap(staged: $0, into: $1) },
            moveItem: { try fm.moveItem(at: $0, to: $1) },
            removeItem: { try? fm.removeItem(at: $0) },
            trash: { try? fm.trashItem(at: $0, resultingItemURL: nil) })
    }
}

extension MoveToApplications {
    static let quarantineAttribute = "com.apple.quarantine"

    static func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// From the item and everything in it. Items without the mark are passed by.
    static func removeQuarantine(under root: URL) {
        removexattr(root.path, quarantineAttribute, XATTR_NOFOLLOW)
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in items {
            removexattr(item.path, quarantineAttribute, XATTR_NOFOLLOW)
        }
    }

    /// Where a translocated app really is. macOS has a function for it in the
    /// Security framework, `SecTranslocateCreateOriginalPathForURL`, that no
    /// public header declares, so it is looked up at run time; nil when it
    /// is not there, and the download then stays where it is.
    static func originalLocation(ofTranslocated app: URL) -> URL? {
        typealias Function = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let original = unsafeBitCast(symbol, to: Function.self)
        guard let url = original(app as CFURL, nil)?.takeRetainedValue() as URL? else { return nil }
        return url
    }
}
