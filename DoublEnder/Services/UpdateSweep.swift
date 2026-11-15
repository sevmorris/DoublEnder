import Foundation

/// Clears up what an update interrupted by a quit, a force quit, a crash or a
/// power cut left behind: a mounted disk image, the image itself, and a staged
/// copy of the app. None of it touches the installed app, but a mounted image
/// stays until the Mac restarts, and a staged copy is a whole app's worth of
/// disk.
///
/// Two kinds of leftover, found two ways:
///   - The folders this app stages into are recorded as they are made
///     (`UpdateStateStore.journal`), so the next launch knows them for its own
///     and removes them, except the one holding the previous version while the
///     new one is on probation, and any another copy of the app is still
///     using: each copy locks its staging folder while it downloads, checks
///     and holds an update in it (`InUseLock`). A copy opened from the disk
///     image while the installed one runs shares the journal, and until
///     2026-11-15 it took every folder on it, deleting the running copy's
///     staged or half-downloaded update; a download cut short that way then
///     counted as a failed install.
///   - The scratch folders `SelfUpdater.stage` downloads and mounts in live in
///     the shared temporary folder, where the sibling apps make theirs under
///     the same name. Only those older than this process and older than an
///     hour are taken: by then no update of any of them is still using one.
enum UpdateSweep {
    static let sharedScratchMinimumAge: TimeInterval = 60 * 60

    struct Tools {
        var isMountPoint: (URL) -> Bool
        var detach: (URL) -> Void

        static let system = Tools(
            isMountPoint: { url in
                var own = stat(), parent = stat()
                guard stat(url.path, &own) == 0,
                      stat(url.deletingLastPathComponent().path, &parent) == 0 else { return false }
                return own.st_dev != parent.st_dev
            },
            detach: { url in
                _ = SelfUpdater.runTool("/usr/bin/hdiutil", ["detach", url.path, "-force", "-quiet"],
                                        deadline: 30, isCancelled: { false })
            })
    }

    /// The staging folders that copies which have ended left, taken off the
    /// journal. A folder another copy still holds locked stays on it, for that
    /// copy to take off itself. Called on the main thread before this run
    /// stages anything, so none of its own can be among them.
    @MainActor
    static func takeLeftovers(store: UpdateStateStore,
                              isInUse: (URL) -> Bool = InUseLock.isHeld) -> [URL] {
        let keep = store.load().probation.map {
            URL(fileURLWithPath: $0.previous).deletingLastPathComponent().standardizedFileURL.path
        }
        var leftovers: [URL] = []
        var stillInUse: [String] = []
        for path in store.journal {
            let folder = URL(fileURLWithPath: path).standardizedFileURL
            if folder.path == keep { continue }
            if isInUse(folder) {
                stillInUse.append(path)
            } else {
                leftovers.append(folder)
            }
        }
        store.journal = stillInUse
        return leftovers
    }

    /// Blocks while images detach; run it off the main thread.
    static func sweep(holders: [URL], temporaryDirectory: URL, processStart: Date,
                      now: Date = Date(), tools: Tools = .system) {
        let fm = FileManager.default
        for holder in holders {
            try? fm.removeItem(at: holder)
        }
        let entries = (try? fm.contentsOfDirectory(at: temporaryDirectory,
                                                   includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in entries where folder.lastPathComponent.hasPrefix(SelfUpdater.scratchPrefix) {
            guard let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                  created < processStart,
                  now.timeIntervalSince(created) >= sharedScratchMinimumAge else { continue }
            let mount = folder.appendingPathComponent("mount", isDirectory: true)
            if tools.isMountPoint(mount) {
                tools.detach(mount)
                // Still mounted: removing the folder would walk into the volume.
                if tools.isMountPoint(mount) { continue }
            }
            try? fm.removeItem(at: folder)
        }
    }
}
