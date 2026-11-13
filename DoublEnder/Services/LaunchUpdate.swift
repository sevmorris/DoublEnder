#if GCS_ENABLED
import AppKit

/// Cloud: brings a guest's copy up to date before the recorder opens.
///
/// A guest usually opens DoublEnder Cloud minutes before a session, and an
/// update prompt then is one more decision for someone who only wants to
/// record. So at launch, before the recorder is built, this checks the Cloud
/// manifest and, when a newer version is there and this copy can replace
/// itself, installs it and relaunches without asking.
///
/// Nothing here may keep a guest from recording. The check gets
/// `checkTimeout` and the install `installBudget`; Skip is always there; and
/// anything else (offline, up to date, on hold, a Mac too old for the new
/// version, a copy that can't replace itself, a failed download, a version
/// this copy rolled back from) opens the recorder as usual. Where the usual
/// prompt after launch has something to add (a copy that has to be moved to
/// Applications first, a check that ran out of time), it still runs.
///
/// The work is `UpdateCoordinator`'s, the same flow Check for Updates… uses, so
/// the menu during this brings this window forward rather than starting a
/// second download. This is the window, and the decision to open the recorder.
@MainActor
final class LaunchUpdate {
    /// How long the manifest check may hold up the recorder.
    static let checkTimeout: Duration = .seconds(5)
    /// How long the download, the copy and the install may, after the check.
    static let installBudget: Duration = .seconds(45)

    private static let appName = "DoublEnder Cloud"

    private let window = UpdatePanel(title: appName, buttonTitle: "Skip")
    private let coordinator: UpdateCoordinator
    private let launch: (_ checkAfterLaunch: Bool) -> Void
    private var finished = false

    /// Starts the check, with its window on screen before this returns, so
    /// SwiftUI finds a window at launch and presents no scene of its own.
    /// `launch` opens the recorder; `checkAfterLaunch` says whether the usual
    /// update check after launch still has something to offer.
    /// It is not called when the update installs, since the app relaunches.
    @discardableResult
    static func run(coordinator: UpdateCoordinator? = nil,
                    then launch: @escaping (_ checkAfterLaunch: Bool) -> Void) -> LaunchUpdate {
        let update = LaunchUpdate(coordinator: coordinator ?? .shared, launch: launch)
        update.start()
        return update
    }

    private init(coordinator: UpdateCoordinator, launch: @escaping (_ checkAfterLaunch: Bool) -> Void) {
        self.coordinator = coordinator
        self.launch = launch
    }

    private func start() {
        window.showProgress("Checking for updates…", fraction: nil)
        window.onButton = { [weak self] in
            guard let self else { return }
            // Stops the download or the copy where it is. The install itself is
            // one step in one pass of the run loop, so Skip lands before it or
            // not at all.
            self.coordinator.cancel()
            // The guest chose to go on, so the prompt after launch would only ask again.
            self.finish(checkAfterLaunch: false)
        }
        window.show()
        // The task holds self until it ends, and it ends in finish or a relaunch.
        Task { @MainActor in
            let outcome = await coordinator.runAtLaunch(window: window, checkTimeout: Self.checkTimeout,
                                                        budget: Self.installBudget)
            switch outcome {
            case .relaunching:
                window.showProgress("Relaunching…", fraction: nil)
            case .openRecorder(let checkAfterLaunch):
                finish(checkAfterLaunch: checkAfterLaunch)
            }
        }
    }

    /// Opens the recorder, once. This window leaves the screen first: building the
    /// recorder can block the main thread on the microphone prompt (a first launch),
    /// and "Checking for updates…" shouldn't sit behind it. The change reaches the
    /// screen only when the run loop next goes idle, so the recorder waits for that;
    /// the pause makes sure the run loop does.
    ///
    /// It turns transparent rather than ordering out: with no window on screen,
    /// AppKit counts the last window as closed even without a close, and this app
    /// then quits. It is closed once the recorder is up.
    ///
    /// The recorder opens from the run loop, not from a task. `launch` goes on to
    /// crash recovery and the pending-upload prompt, which are modal, and a modal
    /// started inside a main actor task stops the main queue (see `MainRunLoop`):
    /// in 2.8.3cr the recovery dialog never heard that its conversion was done.
    private func finish(checkAfterLaunch: Bool) {
        guard !finished else { return }
        finished = true
        window.makeTransparent()
        // The closure holds self until the recorder is up.
        MainRunLoop.perform(after: 0.1) {
            self.launch(checkAfterLaunch)
            self.window.close()
        }
    }
}
#endif
