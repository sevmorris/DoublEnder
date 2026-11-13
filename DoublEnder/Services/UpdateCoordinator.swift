import AppKit
import OSLog

private let logger = Logger(subsystem: "io.github.sevmorris.DoublEnder", category: "UpdateCoordinator")

/// What the offer says.
struct UpdateOffer: Equatable {
    var appName: String
    var version: String
    /// Why this copy cannot replace itself, or nil when it can.
    var obstacle: String?
    var hasReleaseNotes: Bool

    var canInstall: Bool { obstacle == nil }
}

enum UpdateOfferChoice: Equatable {
    case install
    case download
    case releaseNotes
    case notNow
}

/// The updater's dialogs and its progress window.
@MainActor
protocol UpdatePresenting: AnyObject {
    func offer(_ offer: UpdateOffer) -> UpdateOfferChoice
    /// True for Relaunch Now.
    func confirmRelaunch(appName: String, version: String) -> Bool
    /// True for Download.
    func failure(appName: String, message: String) -> Bool
    func inform(title: String, text: String)
    func makeProgress(title: String, buttonTitle: String, onButton: @escaping () -> Void) -> UpdateProgressShowing
}

enum UpdateFailure: LocalizedError, Equatable {
    /// The staged copy did not start when it was tried (`UpdateSelfTest`).
    case selfTest
    /// Cloud's launch install found the app busy, which it never waits for.
    case busy

    var errorDescription: String? {
        switch self {
        case .selfTest:
            return "The new version didn't start when it was tried, so it was not installed."
        case .busy:
            return "The app was busy, so the update was not installed."
        }
    }
}

/// The one place an update runs, from the check to the relaunch.
///
/// Before this, DoublEnder had two update flows that knew nothing of each
/// other: Cloud's install at launch, and the prompt behind Check for Updates…
/// and the check after launch. Each kept its own window and its own idea of
/// busy, so the menu could start a second download beside the first, and the
/// first to finish replaced the app under the other. Here there is one flow
/// at a time (`phase`), and asking again while one runs brings its window
/// forward. It runs on `SelfUpdater`'s steps, so a release is vetted exactly as
/// the sibling apps vet one; `SelfUpdateFlow`, the shared prompt, is not used.
///
/// The rules it keeps:
///   - The download, the disk image and the copy run only while no take, no
///     upload and no recovery does (`AppActivity.blocksHeavyWork`), so they
///     never compete with one for the disk or the network. A take that starts
///     meanwhile stops them, and they start again once it is over.
///   - The new version replaces the app only when nothing at all is under way
///     (`AppActivity.blocksRelaunch`), and if the update had to wait for that,
///     it asks first: a relaunch would clear what is on screen.
///   - No dialog of the updater's opens over work in progress, and none opens
///     from inside a main actor task, where it would stop the main queue
///     (`ModalGate.runFromRunLoop`). A failure that happens during a take is
///     told once the take is over.
///   - The install itself is one synchronous step (`UpdateCommit`), with no
///     suspension from its last check to the quit.
@MainActor
final class UpdateCoordinator {

    enum Phase: Equatable {
        case idle
        case checking
        case downloading
        case staging
        /// For the app to finish what it is doing.
        case waiting
        case confirming
        case committing
        case relaunching
    }

    enum Mode: Equatable {
        /// Asked for: the prompt, from the menu or the check after launch.
        case interactive
        /// Cloud's install at launch, unprompted, before the recorder exists.
        case launch
    }

    enum InstallOutcome: Equatable {
        case committed
        case cancelled
        case declined
        case failed(String)
    }

    enum LaunchOutcome: Equatable {
        case openRecorder(checkAfterLaunch: Bool)
        case relaunching
    }

    struct Environment {
        var appName: String
        /// Shown while the update waits for the app.
        var busyMessage: String
        var showsReleaseNotes: Bool
        var installedURL: URL
        var check: @MainActor () async -> UpdateChecker.Result
        var obstacle: @MainActor () async -> SelfUpdater.Obstacle?
        /// A new folder on the installed app's volume to stage into.
        var makeHolder: @MainActor () throws -> URL
        /// Downloads, vets and stages into the holder; cancellable throughout.
        var stage: @MainActor (_ download: URL, _ holder: URL, _ mode: Mode,
                               _ progress: @escaping @Sendable (Double) -> Void) async throws -> URL
        /// `UpdateCommit`, or a stand-in. Returns only if the app is not quitting.
        var commit: @MainActor (StagedUpdate) throws -> Void
        var removeFolder: @MainActor (URL) -> Void
        var activity: AppActivity
        var presenter: UpdatePresenting
        var store: UpdateStateStore
        var openURL: @MainActor (URL) -> Void
        var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        var pollInterval: Duration = .milliseconds(500)
    }

    private(set) var phase: Phase = .idle
    private let env: Environment
    private var progress: UpdateProgressShowing?
    private var work: Task<InstallOutcome, Never>?
    /// Set by `cancel`, and read where `Task.isCancelled` cannot be: in the
    /// pass of the run loop that installs.
    private var cancelRequested = false
    private var budgetExpired = false
    private var holder: URL?
    private var failureGeneration = 0

    init(environment: Environment) {
        env = environment
    }

    /// Calls off the flow under way, wherever it is: a download, a tool, a wait.
    func cancel() {
        cancelRequested = true
        work?.cancel()
    }

    // MARK: - The menu, and the check after launch

    func checkForUpdates(silent: Bool) async {
        guard phase == .idle else {
            progress?.bringForward()
            return
        }
        // A newer attempt makes an older failure not worth telling.
        failureGeneration += 1
        cancelRequested = false
        phase = .checking
        let result = await env.check()
        await handle(result, silent: silent)
        if phase != .relaunching { phase = .idle }
    }

    private func handle(_ result: UpdateChecker.Result, silent: Bool) async {
        switch result {
        case .upToDate(let version):
            guard !silent else { return }
            await inform("You're up to date", "\(env.appName) \(version) is the latest version.")

        case .needsNewerMacOS(let version, let minimum, let installed):
            // Nothing this Mac can install, so the check at launch says nothing.
            guard !silent else { return }
            let os = UpdateChecker.describe(ProcessInfo.processInfo.operatingSystemVersion)
            await inform("\(env.appName) \(version) needs macOS \(minimum)",
                         "This Mac has macOS \(os), so \(env.appName) \(installed) is the newest version it can run.")

        case .onHold(let version):
            guard !silent else { return }
            await inform("\(env.appName) \(version) is on hold",
                         "The new version is not being installed for now. Check again later.")

        case .error(let message):
            guard !silent else { return }
            await inform("Update Check Failed", message)

        case .available(let version, let downloadURL, let releaseURL):
            // A version this copy rolled back from is offered only when asked for.
            if silent && UpdateRollback.isSkipped(version, store: env.store) { return }
            let obstacle = await env.obstacle()
            let offer = UpdateOffer(appName: env.appName, version: version,
                                    obstacle: obstacle.map { Self.explanation(of: $0, at: env.installedURL) },
                                    hasReleaseNotes: env.showsReleaseNotes)
            let presenter = env.presenter
            let activity = env.activity
            // The check at launch can answer after work has begun. Asked in the
            // same pass of the run loop as the dialog opens, so RECORD pressed
            // while the copy was being checked keeps it away.
            let choice = await ModalGate.runFromRunLoop(silent ? .prompt : .required, activity: activity,
                                                        unless: { silent && activity.blocksRelaunch }) {
                presenter.offer(offer)
            }
            switch choice {
            case .install?:
                let outcome = await install(version: version, downloadURL: downloadURL, mode: .interactive)
                if case .failed(let message) = outcome {
                    reportWhenIdle(message, downloadURL: downloadURL)
                }
            case .download?:
                env.openURL(downloadURL)
            case .releaseNotes?:
                env.openURL(releaseURL)
            case .notNow?, nil:
                return
            }
        }
    }

    private func inform(_ title: String, _ text: String) async {
        let presenter = env.presenter
        await ModalGate.runFromRunLoop(activity: env.activity) { presenter.inform(title: title, text: text) }
    }

    /// A failure is told once nothing is under way, and only once. A take that
    /// started during the download must not end up behind an alert.
    private func reportWhenIdle(_ message: String, downloadURL: URL) {
        failureGeneration += 1
        let generation = failureGeneration
        Task { @MainActor in
            let activity = env.activity
            let presenter = env.presenter
            let appName = env.appName
            while generation == failureGeneration {
                let superseded = { generation != self.failureGeneration }
                if !activity.blocksRelaunch && phase == .idle {
                    let shown = await ModalGate.runFromRunLoop(activity: activity, unless: {
                        superseded() || activity.blocksRelaunch || self.phase != .idle
                    }) {
                        presenter.failure(appName: appName, message: message)
                    }
                    if let download = shown {
                        if download { env.openURL(downloadURL) }
                        return
                    }
                }
                guard (try? await env.sleep(env.pollInterval)) != nil else { return }
            }
        }
    }

    // MARK: - Cloud, at launch

    /// Cloud's install before the recorder opens. Anything but an install opens
    /// the recorder; `checkAfterLaunch` says whether the usual prompt after
    /// launch still has something to offer.
    func runAtLaunch(window: UpdateProgressShowing, checkTimeout: Duration, budget: Duration) async -> LaunchOutcome {
        guard phase == .idle else { return .openRecorder(checkAfterLaunch: false) }
        cancelRequested = false
        budgetExpired = false
        progress = window
        defer {
            if progress === window { progress = nil }
            if phase != .relaunching { phase = .idle }
        }
        phase = .checking
        window.showProgress("Checking for updates…", fraction: nil)

        guard let result = await withDeadline(checkTimeout, env.check) else {
            logger.notice("Launch update check took longer than \(checkTimeout, privacy: .public)")
            return .openRecorder(checkAfterLaunch: true)
        }
        // Skipped while it was checking: the recorder is already open.
        if cancelRequested { return .openRecorder(checkAfterLaunch: false) }

        switch result {
        case .upToDate, .needsNewerMacOS, .onHold:
            // The check after launch would find the same, and it says nothing either way.
            return .openRecorder(checkAfterLaunch: false)
        case .error(let message):
            logger.notice("Launch update check failed: \(message, privacy: .public)")
            return .openRecorder(checkAfterLaunch: true)
        case .available(let version, let downloadURL, _):
            if UpdateRollback.isSkipped(version, store: env.store) {
                logger.notice("Not installing \(version, privacy: .public): this copy rolled back from it")
                return .openRecorder(checkAfterLaunch: false)
            }
            guard UpdateRollback.shouldInstallAutomatically(version, store: env.store) else {
                // It failed here before; the prompt after launch offers it, and
                // the download when it fails again.
                return .openRecorder(checkAfterLaunch: true)
            }
            let obstacle = await env.obstacle()
            if cancelRequested { return .openRecorder(checkAfterLaunch: false) }
            // The prompt after launch says what's in the way, and offers the download.
            guard obstacle == nil else { return .openRecorder(checkAfterLaunch: true) }

            let timer = Task { @MainActor in
                guard (try? await env.sleep(budget)) != nil else { return }
                budgetExpired = true
                cancel()
            }
            let outcome = await install(version: version, downloadURL: downloadURL, mode: .launch)
            timer.cancel()
            switch outcome {
            case .committed:
                return .relaunching
            case .cancelled, .declined:
                if budgetExpired {
                    logger.notice("Launch update took longer than \(budget, privacy: .public)")
                }
                return .openRecorder(checkAfterLaunch: budgetExpired)
            case .failed(let message):
                logger.error("Launch update failed: \(message, privacy: .public)")
                UpdateRollback.recordFailure(of: version, store: env.store)
                // The installed app is as it was. The prompt after launch offers
                // the update again, and the download when it fails a second time.
                return .openRecorder(checkAfterLaunch: true)
            }
        }
    }

    private func withDeadline<T: Sendable>(_ limit: Duration, _ work: @escaping @MainActor () async -> T) async -> T? {
        let sleep = env.sleep
        return await withTaskGroup(of: T?.self) { group in
            group.addTask { @MainActor in await work() }
            group.addTask { @MainActor in
                try? await sleep(limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Quitting

    /// A quit while a download or a copy is under way: it is called off, and
    /// the quit waits up to `limit` for the disk image to come off and the copy
    /// to go, then calls `reply`. False when there is nothing to wait for.
    func cancelBeforeQuit(limit: TimeInterval = 2, then reply: @escaping @MainActor () -> Void) -> Bool {
        guard phase == .downloading || phase == .staging, let work else { return false }
        let once = LockedFlag()
        let answer: @MainActor () -> Void = {
            guard !once.isSet else { return }
            once.set()
            reply()
        }
        cancel()
        MainRunLoop.perform(after: limit) { answer() }
        Task { @MainActor in
            _ = await work.value
            MainRunLoop.perform { answer() }
        }
        return true
    }

    /// The app is quitting for some other reason than an update. A staged copy
    /// waiting for its turn goes with it.
    func cleanUpForQuit() {
        guard phase != .committing && phase != .relaunching else { return }
        discardHolder()
    }

    // MARK: - Installing

    func install(version: String, downloadURL: URL, mode: Mode) async -> InstallOutcome {
        if mode == .interactive {
            progress = env.presenter.makeProgress(title: "Updating \(env.appName)", buttonTitle: "Cancel") { [weak self] in
                self?.cancel()
            }
        }
        let task = Task { @MainActor in await self.runInstall(version: version, downloadURL: downloadURL, mode: mode) }
        work = task
        let outcome = await task.value
        work = nil
        if mode == .interactive {
            progress?.close()
            progress = nil
        }
        return outcome
    }

    private enum StagingInterrupted: Error {
        case heavyWork
    }

    private enum CommitDecision {
        case busy
        case cancelled
        case declined
        case committed
        case failed(String)
    }

    private func runInstall(version: String, downloadURL: URL, mode: Mode) async -> InstallOutcome {
        var waited = false
        let staged: URL

        // 1. Download and stage, while nothing that matters more is running.
        while true {
            if cancelRequested { return .cancelled }
            if env.activity.blocksHeavyWork {
                guard mode == .interactive else { return .failed(UpdateFailure.busy.localizedDescription) }
                waited = true
                showWaiting()
                guard await pause() else { return .cancelled }
                continue
            }
            let folder: URL
            do {
                folder = try env.makeHolder()
            } catch {
                return .failed(error.localizedDescription)
            }
            holder = folder
            env.store.journal.append(folder.path)
            phase = .downloading
            progress?.showProgress("Downloading \(env.appName) \(version)…", fraction: 0)
            do {
                staged = try await stageUnlessInterrupted(downloadURL: downloadURL, holder: folder, version: version, mode: mode)
                break
            } catch StagingInterrupted.heavyWork {
                discardHolder()
                waited = true
                continue
            } catch {
                discardHolder()
                if cancelRequested || error is CancellationError { return .cancelled }
                return .failed(error.localizedDescription)
            }
        }

        // 2. Wait for the app to be idle, ask when it had to wait, and install.
        let update = StagedUpdate(version: version, staged: staged, installed: env.installedURL)
        while true {
            if cancelRequested {
                discardHolder()
                return .cancelled
            }
            if env.activity.blocksRelaunch {
                guard mode == .interactive else {
                    discardHolder()
                    return .failed(UpdateFailure.busy.localizedDescription)
                }
                waited = true
                showWaiting()
                guard await pause() else {
                    discardHolder()
                    return .cancelled
                }
                continue
            }
            let ask = waited && mode == .interactive
            let decision = await MainRunLoop.run { self.decide(update, ask: ask) }
            switch decision {
            case .busy where mode == .interactive:
                waited = true
            case .busy:
                discardHolder()
                return .failed(UpdateFailure.busy.localizedDescription)
            case .cancelled:
                discardHolder()
                return .cancelled
            case .declined:
                discardHolder()
                return .declined
            case .committed:
                // The previous version is in the folder now, and probation owns it.
                if let holder { env.store.journal.removeAll { $0 == holder.path } }
                holder = nil
                return .committed
            case .failed(let message):
                discardHolder()
                return .failed(message)
            }
        }
    }

    /// One pass of the run loop, with no suspension in it: the last checks, the
    /// question when the update had to wait, and the install, which quits.
    private func decide(_ update: StagedUpdate, ask: Bool) -> CommitDecision {
        if cancelRequested { return .cancelled }
        if env.activity.blocksRelaunch { return .busy }
        if ask {
            phase = .confirming
            let presenter = env.presenter
            let appName = env.appName
            guard let relaunch = ModalGate.run(activity: env.activity, {
                presenter.confirmRelaunch(appName: appName, version: update.version)
            }) else { return .busy }
            guard relaunch else { return .declined }
        }
        phase = .committing
        do {
            try env.commit(update)
        } catch UpdateCommit.Refusal.busy {
            return .busy
        } catch {
            return .failed(error.localizedDescription)
        }
        phase = .relaunching
        return .committed
    }

    private func stageUnlessInterrupted(downloadURL: URL, holder: URL, version: String, mode: Mode) async throws -> URL {
        let downloading = "Downloading \(env.appName) \(version)…"
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.phase == .downloading || self.phase == .staging else { return }
                    if fraction < 1 {
                        self.progress?.showProgress(downloading, fraction: fraction)
                    } else {
                        self.phase = .staging
                        self.progress?.showProgress("Checking the download…", fraction: nil)
                    }
                }
            }
        }
        let stage = env.stage
        let activity = env.activity
        let sleep = env.sleep
        let interval = env.pollInterval
        return try await withThrowingTaskGroup(of: URL?.self) { group in
            group.addTask { @MainActor in try await stage(downloadURL, holder, mode, report) }
            if mode == .interactive {
                // A take that starts now stops the download or the copy.
                group.addTask { @MainActor in
                    while true {
                        try await sleep(interval)
                        if activity.blocksHeavyWork { return nil }
                    }
                }
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            guard let staged = first else { throw StagingInterrupted.heavyWork }
            return staged
        }
    }

    private func showWaiting() {
        phase = .waiting
        progress?.showProgress(env.busyMessage, fraction: nil)
    }

    /// Waits a poll interval. False when the install was called off.
    private func pause() async -> Bool {
        do {
            try await env.sleep(env.pollInterval)
        } catch {
            return false
        }
        return !cancelRequested && !Task.isCancelled
    }

    private func discardHolder() {
        guard let holder else { return }
        env.removeFolder(holder)
        env.store.journal.removeAll { $0 == holder.path }
        self.holder = nil
    }

    /// Why this copy has to be replaced by hand.
    static func explanation(of obstacle: SelfUpdater.Obstacle, at app: URL) -> String {
        switch obstacle {
        case .notARelease:
            return "This copy isn't a signed release, so it can't replace itself."
        case .readOnlyLocation:
            return "This copy can't replace itself where it is. Move it to the Applications folder and open it from there."
        case .notWritable:
            return "You don't have permission to replace the copy at \(app.path)."
        }
    }
}

// MARK: - The app's own

extension UpdateCoordinator {
    static let shared = UpdateCoordinator(environment: .live())
}

extension UpdateCoordinator.Environment {
    /// What a download may take when it was asked for.
    static let interactiveLimits = SelfUpdater.DownloadLimits(
        stallTimeout: 30, resourceTimeout: 15 * 60, maximumBytes: 512 << 20,
        // An update must leave room to start a take in either format.
        reserve: DiskSpaceChecker.minimumFreeBytes(for: .wav))
    /// At launch a guest is waiting: a connection that goes quiet is given up
    /// sooner, and the whole install has `LaunchUpdate.installBudget`.
    static let launchLimits = SelfUpdater.DownloadLimits(
        stallTimeout: 15, resourceTimeout: 15 * 60, maximumBytes: 512 << 20,
        reserve: DiskSpaceChecker.minimumFreeBytes(for: .wav))

    @MainActor
    static func live() -> Self {
        let installed = Bundle.main.bundleURL
        let expected = SelfUpdater.Expected.running(.main)
        let store = UpdateStateStore.app
        let activity = AppActivity.shared
        #if GCS_ENABLED
        let busyMessage = "\(updaterAppName) can update when your recording has finished uploading."
        let showsReleaseNotes = false
        #else
        let busyMessage = "\(updaterAppName) can update when your recording has finished."
        let showsReleaseNotes = true
        #endif
        return Self(
            appName: updaterAppName,
            busyMessage: busyMessage,
            showsReleaseNotes: showsReleaseNotes,
            installedURL: installed,
            check: { await UpdateChecker().check() },
            obstacle: {
                await Task.detached(priority: .utility) {
                    SelfUpdater.obstacle(for: installed, requirement: expected.appRequirement)
                }.value
            },
            makeHolder: {
                try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                            appropriateFor: installed, create: true)
            },
            stage: { downloadURL, holder, mode, progress in
                let request = URLRequest(url: downloadURL, cachePolicy: .reloadIgnoringLocalCacheData)
                let staged = try await SelfUpdater.stage(from: request, replacing: installed, expected: expected,
                                                         limits: mode == .launch ? launchLimits : interactiveLimits,
                                                         into: holder, progress: progress)
                // Before it replaces anything: does it start at all?
                guard await UpdateSelfTest.passesOffMain(staged) else { throw UpdateFailure.selfTest }
                return staged
            },
            commit: { update in
                try UpdateCommit.live(store: store, activity: activity, expected: expected)(update)
            },
            removeFolder: { try? FileManager.default.removeItem(at: $0) },
            activity: activity,
            presenter: AlertUpdatePresenter(),
            store: store,
            openURL: { NSWorkspace.shared.open($0) })
    }
}
