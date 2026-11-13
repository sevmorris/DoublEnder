import Foundation
import OSLog

private let logger = Logger(subsystem: "io.github.sevmorris.DoublEnder", category: "UpdateRollback")

/// What the updater remembers between launches.
struct UpdateState: Codable, Equatable {
    /// A version just installed that has not yet shown it can stay up.
    struct Probation: Codable, Equatable {
        /// The version that was replaced, and is kept until this one is healthy.
        var from: String
        /// The version on probation, as its own Info.plist gives it.
        var to: String
        /// Where the previous version is: the folder the swap left it in.
        var previous: String
        /// The copy that was replaced. A start of `to` from anywhere else (a
        /// disk image, a second copy) is not this one, and is not counted.
        var installed: String?
        /// Starts of `to` so far, none of which reached a healthy mark.
        var launches: Int
    }

    struct Failures: Codable, Equatable {
        var count: Int
        var last: Date
    }

    var probation: Probation?
    /// A version this copy rolled back from. It is not installed unasked again.
    var skipped: String?
    /// Automatic installs that failed, by version.
    var failures: [String: Failures] = [:]
}

/// The state's file, and beside it the probation marker the relaunch helper
/// watches. A file, not defaults: a version that crashes at launch has to have
/// its count on disk before it crashes.
final class UpdateStateStore {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    /// Present from the swap until the new version is healthy or rolled back.
    var markerURL: URL { url.deletingLastPathComponent().appendingPathComponent("update-probation") }

    /// Folders with a staged copy in them or on its way, for the sweep at launch.
    var journalURL: URL { url.deletingLastPathComponent().appendingPathComponent("update-staging.json") }

    /// In Application Support, under the bundle identifier, so the Local and
    /// Cloud builds stay apart. A test run gets a folder in the temporary
    /// directory instead: nothing a test does may reach the real one.
    static let app: UpdateStateStore = {
        let bundleID = Bundle.main.bundleIdentifier ?? "io.github.sevmorris.DoublEnder"
        let base: URL
        if AppLauncher.isHostingTests {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("\(bundleID).tests-update-state")
        } else {
            base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory).appendingPathComponent(bundleID)
        }
        return UpdateStateStore(url: base.appendingPathComponent("update-state.json"))
    }()

    /// A missing or unreadable file is an empty state: the updater must never
    /// keep the app from starting.
    func load() -> UpdateState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(UpdateState.self, from: data) else { return UpdateState() }
        return state
    }

    func save(_ state: UpdateState) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        } catch {
            logger.error("Update state not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setMarker(_ present: Bool) {
        if present {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: markerURL.path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: markerURL)
        }
    }

    // MARK: - Staging journal

    var journal: [String] {
        get {
            guard let data = try? Data(contentsOf: journalURL),
                  let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return paths
        }
        set {
            if newValue.isEmpty {
                try? FileManager.default.removeItem(at: journalURL)
                return
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(newValue).write(to: journalURL, options: .atomic)
        }
    }
}

/// Keeps the previous version until the new one has shown it can stay up, and
/// puts it back when the new one cannot.
///
/// An update used to delete the version it replaced at once. `SelfUpdater.vet`
/// checks a new version's signature, version, minimum macOS and architecture,
/// not that it starts, and Cloud installs without asking: a build that crashed
/// at launch would have reached every guest at their next launch, minutes
/// before a session, with nothing to go back to.
///
/// So the swap leaves the previous version where it lands, and a record says
/// so. The new version counts its starts at the top of `main`. Once the
/// recorder has been up for a few seconds, or the app quits cleanly, it is
/// healthy: the record and the old copy go. A third start with no healthy one
/// before it swaps the old copy back in, from this process (macOS lets an app
/// replace one signed by its own team), marks the bad version as skipped, and
/// relaunches. A version that fails before `main` runs is the self-test's to
/// catch, before the swap (`UpdateSelfTest`).
///
/// Everything here fails open: whatever goes wrong, the app starts.
enum UpdateRollback {
    /// Starts without a healthy mark before the previous version is put back.
    static let maximumLaunches = 2
    /// After this many failed automatic installs of one version, the automatic
    /// attempt rests for `failureRest`: a Mac where staging always fails (disk
    /// images blocked, no room) would otherwise pay for a download and a failed
    /// install at every launch.
    static let maximumFailures = 2
    static let failureRest: TimeInterval = 24 * 60 * 60

    enum LaunchDecision: Equatable {
        case proceed
        /// The previous version is back in place and about to be opened; this
        /// process should end.
        case rolledBack
    }

    /// What `atLaunch` needs of the world.
    struct Tools {
        /// True when the copy at the URL is a signed release of this app at exactly this version.
        var isRelease: (_ copy: URL, _ version: String) -> Bool
        var swap: (_ previous: URL, _ installed: URL) throws -> Void
        var prepareRelaunch: (URL) throws -> UpdateCommit.Undo
        /// Removes a copy and the folder made for it.
        var discard: (URL) -> Void
    }

    // MARK: - At the swap

    /// Called before the swap. `previous` is where the staged copy is now and
    /// the replaced version will be once the two are exchanged.
    ///
    /// A version still on probation is replaced before it proved itself (Cloud
    /// found a newer one at its first launch): its own previous copy goes, and
    /// the version now running becomes the one to go back to.
    static func arm(from: String, to: String, previous: URL, installed: URL, store: UpdateStateStore,
                    discard: (URL) -> Void = { SelfUpdater.discard($0) }) {
        var state = store.load()
        if let older = state.probation, older.previous != previous.path {
            discard(URL(fileURLWithPath: older.previous))
        }
        state.probation = UpdateState.Probation(from: from, to: to, previous: previous.path,
                                                installed: installed.path, launches: 0)
        store.save(state)
        store.setMarker(true)
    }

    /// The swap failed: nothing is on probation.
    static func disarm(store: UpdateStateStore) {
        var state = store.load()
        state.probation = nil
        store.save(state)
        store.setMarker(false)
    }

    // MARK: - At launch

    static func atLaunch(runningVersion: String, installed: URL, store: UpdateStateStore, tools: Tools) -> LaunchDecision {
        var state = store.load()
        guard var probation = state.probation else {
            store.setMarker(false)
            return .proceed
        }
        let previous = URL(fileURLWithPath: probation.previous)

        if let path = probation.installed,
           URL(fileURLWithPath: path).standardizedFileURL.path != installed.standardizedFileURL.path {
            // Another copy of the version on probation: it proves nothing either way.
            return .proceed
        }
        guard probation.to == runningVersion else {
            // Not the version on probation: the swap never happened, or the
            // app was changed by hand since. Either way the record is stale,
            // and so is the copy it points to.
            state.probation = nil
            store.save(state)
            store.setMarker(false)
            tools.discard(previous)
            return .proceed
        }

        probation.launches += 1
        state.probation = probation
        store.save(state)
        guard probation.launches > maximumLaunches else { return .proceed }

        // This version has started more than twice and never stayed up.
        func giveUp(_ why: String) -> LaunchDecision {
            logger.error("Rollback from \(probation.to, privacy: .public) not possible: \(why, privacy: .public)")
            state.probation = nil
            store.save(state)
            store.setMarker(false)
            return .proceed
        }
        guard tools.isRelease(previous, probation.from) else {
            return giveUp("the previous version is gone or is not what was replaced")
        }
        do {
            let relaunch = try tools.prepareRelaunch(installed)
            do {
                try tools.swap(previous, installed)
            } catch {
                relaunch.cancel()
                throw error
            }
        } catch {
            return giveUp(error.localizedDescription)
        }
        logger.error("\(probation.to, privacy: .public) did not stay up; \(probation.from, privacy: .public) is back in place")
        state.probation = nil
        state.skipped = probation.to
        store.save(state)
        store.setMarker(false)
        // The folder now holds the version that failed.
        tools.discard(previous)
        return .rolledBack
    }

    // MARK: - Once the app is up

    /// The running version has shown it can stay up. Nothing happens unless it
    /// is the one on probation: the old version's own quit, right after it arms
    /// probation for the new one, comes through here too.
    static func markHealthy(runningVersion: String, store: UpdateStateStore, discard: (URL) -> Void) {
        var state = store.load()
        guard let probation = state.probation, probation.to == runningVersion else { return }
        state.probation = nil
        store.save(state)
        store.setMarker(false)
        discard(URL(fileURLWithPath: probation.previous))
    }

    // MARK: - What not to install unasked

    /// Versions compare by their numbers alone: the Local check reports
    /// "2.8.4" for an app that calls itself "2.8.4lr".
    private static func key(_ version: String) -> String {
        SelfUpdater.numericVersion(version)
    }

    static func isSkipped(_ version: String, store: UpdateStateStore) -> Bool {
        store.load().skipped.map(key) == key(version)
    }

    static func recordFailure(of version: String, store: UpdateStateStore, now: Date = Date()) {
        var state = store.load()
        let version = key(version)
        // Only the version at hand is worth remembering.
        state.failures = state.failures.filter { $0.key == version }
        state.failures[version] = UpdateState.Failures(count: (state.failures[version]?.count ?? 0) + 1, last: now)
        store.save(state)
    }

    static func shouldInstallAutomatically(_ version: String, store: UpdateStateStore, now: Date = Date()) -> Bool {
        if isSkipped(version, store: store) { return false }
        guard let failures = store.load().failures[key(version)], failures.count >= maximumFailures else { return true }
        return now.timeIntervalSince(failures.last) > failureRest
    }
}

extension UpdateRollback.Tools {
    /// The real thing, for this app's bundle identifier.
    static func live(bundleID: String) -> Self {
        Self(
            isRelease: { copy, version in
                bundleVersion(at: copy) == version
                    && SelfUpdater.isSigned(copy, requirement: SelfUpdater.appRequirement(bundleID: bundleID))
            },
            swap: { try SelfUpdater.swap(staged: $0, into: $1) },
            prepareRelaunch: { installed in
                let helper = try UpdateRelauncher.prepare(toOpen: installed, marker: nil)
                return UpdateCommit.Undo { helper.terminate() }
            },
            discard: { SelfUpdater.discard($0) })
    }
}

/// The version an app's own Info.plist gives, read from the file: `Bundle`
/// keeps what it read about a path, and a copy can change under it.
func bundleVersion(at app: URL) -> String? {
    guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    return info["CFBundleShortVersionString"] as? String
}

/// A flag one thread raises and another reads.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}

/// Asks a staged copy whether it starts at all, before it replaces anything.
///
/// The copy is run with `argument`, and answers by exiting 0 from the first
/// lines of `main`, before AppKit comes up. Getting that far takes everything
/// that kills a build before its own code runs: a library or symbol the Mac
/// lacks, an executable the loader refuses, a slice that is not there, a
/// signature the kernel rejects. Those are the failures no rollback inside the
/// app can catch, and here the old version is still installed.
///
/// Only a copy whose Info.plist says it answers is asked: one that does not
/// know the argument would open as a second recorder.
enum UpdateSelfTest {
    static let argument = "--selftest"
    static let infoKey = "UpdateSelfTest"
    static let deadline: TimeInterval = 20

    /// The first thing `main` does.
    static func exitIfAsked(arguments: [String] = CommandLine.arguments) {
        if arguments.dropFirst().contains(argument) { exit(0) }
    }

    /// `passes`, off the main thread, stopped if the task is cancelled.
    static func passesOffMain(_ app: URL) async -> Bool {
        let cancelled = LockedFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: passes(app, isCancelled: { cancelled.isSet }))
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    /// True when the copy starts, or does not say it can be asked.
    static func passes(_ app: URL, isCancelled: @escaping @Sendable () -> Bool = { false },
                       run: (String, [String], TimeInterval, @Sendable () -> Bool) -> SelfUpdater.Tools.Outcome
                           = { SelfUpdater.runTool($0, $1, deadline: $2, isCancelled: $3) }) -> Bool {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String else { return false }
        guard info[infoKey] as? Bool == true else { return true }
        let binary = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
        return run(binary.path, [argument], deadline, isCancelled) == .success
    }
}
