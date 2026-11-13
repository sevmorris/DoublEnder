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
///     new one is on probation.
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

    /// The staging folders earlier runs left, taken off the journal. Called on
    /// the main thread before this run stages anything, so none of its own can
    /// be among them.
    @MainActor
    static func takeLeftovers(store: UpdateStateStore) -> [URL] {
        let keep = store.load().probation.map {
            URL(fileURLWithPath: $0.previous).deletingLastPathComponent().standardizedFileURL.path
        }
        let paths = store.journal
        store.journal = []
        return paths
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { $0.path != keep }
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
