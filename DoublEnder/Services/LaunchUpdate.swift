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
///
/// Before the check, a copy that can never update itself where it is (on its
/// disk image, or translocated from Downloads) is offered a move to the
/// Applications folder (`MoveToApplications`), and a copy as new as this one
/// that is already there is opened instead. Not Now opens the recorder at once:
/// the check would only find a copy that cannot install anything, and the
/// prompt after launch could only offer a download.
@MainActor
final class LaunchUpdate {
    /// How long the manifest check may hold up the recorder.
    static let checkTimeout: Duration = .seconds(5)
    /// How long the download, the copy and the install may, after the check.
    static let installBudget: Duration = .seconds(45)

    private static let appName = "DoublEnder Cloud"

    private let window = UpdatePanel(title: appName, buttonTitle: "Skip")
    private let coordinator: UpdateCoordinator
    private let moving: LaunchMove
    private let launch: (_ checkAfterLaunch: Bool) -> Void
    private var finished = false
    /// Copying the app to Applications, or handing over to it: Skip would open
    /// the recorder under a quit.
    private var handingOver = false

    /// Starts the check, with its window on screen before this returns, so
    /// SwiftUI finds a window at launch and presents no scene of its own.
    /// `launch` opens the recorder; `checkAfterLaunch` says whether the usual
    /// update check after launch still has something to offer.
    /// It is not called when the update installs, since the app relaunches.
    @discardableResult
    static func run(coordinator: UpdateCoordinator? = nil, moving: LaunchMove? = nil,
                    then launch: @escaping (_ checkAfterLaunch: Bool) -> Void) -> LaunchUpdate {
        let update = LaunchUpdate(coordinator: coordinator ?? .shared, moving: moving ?? .live(), launch: launch)
        update.start()
        return update
    }

    private init(coordinator: UpdateCoordinator, moving: LaunchMove,
                 launch: @escaping (_ checkAfterLaunch: Bool) -> Void) {
        self.coordinator = coordinator
        self.moving = moving
        self.launch = launch
    }

    private func start() {
        window.showProgress("Checking for updates…", fraction: nil)
        window.onButton = { [weak self] in
            guard let self, !self.handingOver else { return }
            // Stops the download or the copy where it is. The install itself is
            // one step in one pass of the run loop, so Skip lands before it or
            // not at all.
            self.coordinator.cancel()
            // The guest chose to go on, so the prompt after launch would only ask again.
            self.finish(checkAfterLaunch: false)
        }
        window.show()
        // A first launch asks Host or Guest before anything is checked, so the
        // window waits out of sight until there is something to check. On
        // screen all the same: SwiftUI has to find it there. Until 2026-11-19
        // "Checking for updates…" animated beside the setup card, checking
        // nothing, until the guest chose.
        let existingMode = moving.storedMode()
        if existingMode == nil {
            window.setHidden(true)
        }
        // The task holds self until it ends, and it ends in finish or a relaunch.
        Task { @MainActor in
            if await settleWhereItRuns(existingMode: existingMode) { return }
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

    /// A copy that cannot update itself where it is: hand over to the installed
    /// copy, or offer the move. On a first launch (`storedMode() == nil`), asks
    /// whether this copy is for a Regular Host or a One-Time Guest first. True
    /// when that settled the launch: the app is quitting for the other copy, or
    /// the recorder is opening.
    private func settleWhereItRuns(existingMode: CloudSessionMode?) async -> Bool {
        if existingMode == .guest {
            finish(checkAfterLaunch: false)
            return true
        }

        let decision = await moving.decide()
        // Skipped while it looked: the recorder is open already.
        if finished { return true }
        switch decision {
        case .stay:
            if existingMode == nil {
                let chosen = await asking { self.moving.askMode(false) } ?? .guest
                moving.saveMode(chosen)
                if chosen == .guest {
                    finish(checkAfterLaunch: false)
                    return true
                }
            }
            window.setHidden(false)
            return false

        case .openInstalled(let installed, let volume):
            if existingMode == nil {
                moving.saveMode(.host)
            }
            setHandingOver(true)
            window.showProgress("Opening \(Self.appName)…", fraction: nil)
            window.setHidden(false)
            if moving.handOff(installed, volume) { return true }
            // The other copy could not be opened: this one carries on.
            setHandingOver(false)
            window.showProgress("Checking for updates…", fraction: nil)
            return false

        case .offer(let offer):
            let move: Bool
            if existingMode == nil {
                let chosen = await asking { self.moving.askMode(true) } ?? .guest
                moving.saveMode(chosen)
                move = (chosen == .host)
            } else {
                move = await asking { self.moving.ask(offer) } ?? false
            }
            guard move else {
                finish(checkAfterLaunch: false)
                return true
            }
            setHandingOver(true)
            window.showProgress("Moving \(Self.appName) to Applications…", fraction: nil)
            switch await moving.move(offer) {
            case .success(let installed):
                window.showProgress("Opening \(Self.appName)…", fraction: nil)
                if moving.handOff(installed, offer.origin.volumeToEject) { return true }
                await ModalGate.runFromRunLoop {
                    self.moving.tell("\(Self.appName) Is in Your Applications Folder",
                                     "Open it from there next time. This time it carries on from where it is.")
                }
            case .failure(let error):
                await ModalGate.runFromRunLoop {
                    self.moving.tell("Couldn't Move \(Self.appName)",
                                     "\(error.localizedDescription) \(Self.appName) carries on from where it is.")
                }
            }
            setHandingOver(false)
            finish(checkAfterLaunch: false)
            return true
        }
    }

    /// One of the launch's own questions, with the window out of sight while
    /// it is up and back afterwards. An answer that opens the recorder retires
    /// the window (`finish`) in the same pass of the run loop, before it is
    /// drawn again.
    private func asking<T>(_ question: @escaping @MainActor () -> T) async -> T? {
        window.setHidden(true)
        let answer = await ModalGate.runFromRunLoop { question() }
        window.setHidden(false)
        return answer
    }

    private func setHandingOver(_ on: Bool) {
        handingOver = on
        window.setButtonEnabled(!on)
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
/// What Cloud's launch does about a copy that cannot update itself where it is.
struct LaunchMove {
    /// The stored or inferred mode, or nil on a first launch.
    var storedMode: @MainActor () -> CloudSessionMode? = { .host }
    /// The first-launch setup card (`Run as Guest` vs `Install/Use as Host`).
    var askMode: @MainActor (_ willMoveToApplications: Bool) -> CloudSessionMode = { _ in .host }
    var saveMode: @MainActor (CloudSessionMode) -> Void = { _ in }
    var decide: @MainActor () async -> MoveToApplications.Decision
    /// The question. True for Move to Applications.
    var ask: @MainActor (MoveToApplications.Offer) -> Bool
    var move: @MainActor (MoveToApplications.Offer) async -> Result<URL, Error>
    /// Arranges for `app` to open once this process has gone, ejecting
    /// `volume` after it, and quits. False when that could not be arranged.
    var handOff: @MainActor (_ app: URL, _ ejecting: URL?) -> Bool
    var tell: @MainActor (_ title: String, _ text: String) -> Void

    static func live() -> LaunchMove {
        let app = Bundle.main.bundleURL
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let tools = MoveToApplications.Tools.live(bundleID: Bundle.main.bundleIdentifier ?? "")
        let defaults = UserDefaults.app
        return LaunchMove(
            storedMode: {
                GuestUninstall.storedOrInferredMode(
                    in: defaults,
                    appURL: app,
                    applicationsFolders: tools.applicationsFolders
                )
            },
            askMode: { willMove in
                CloudSetupPrompt.present(appName: updaterAppName, willMoveToApplications: willMove)
            },
            saveMode: { mode in
                GuestUninstall.setMode(mode, in: defaults)
            },
            decide: {
                let lastMove = defaults.object(forKey: MoveToApplications.lastMoveKey) as? Date
                // It checks signatures: off the main thread.
                return await Task.detached(priority: .userInitiated) {
                    MoveToApplications.decide(app: app, appName: updaterAppName, version: version,
                                              lastMove: lastMove, tools: tools)
                }.value
            },
            ask: { offer in
                let alert = NSAlert()
                alert.window.appearance = NSAppearance(named: .darkAqua)
                alert.messageText = "Move \(offer.appName) to Applications?"
                alert.informativeText = MoveToApplications.explanation(for: offer)
                alert.addButton(withTitle: "Move to Applications")
                alert.addButton(withTitle: "Not Now").keyEquivalent = "\u{1b}"
                return alert.runModal() == .alertFirstButtonReturn
            },
            move: { offer in
                await Task.detached(priority: .userInitiated) {
                    Result { try MoveToApplications.move(offer, version: version, tools: tools) }
                }.value
            },
            handOff: { target, volume in
                // An installed copy put there by hand may still carry its
                // download mark, and would be translocated, stuck, again. It
                // was checked: a signed release of this app.
                if MoveToApplications.hasQuarantine(target) {
                    MoveToApplications.removeQuarantine(under: target)
                }
                do {
                    _ = try UpdateRelauncher.prepare(toOpen: target, marker: nil, ejecting: volume)
                } catch {
                    return false
                }
                // On the main thread, which is the one that exits: written
                // from any other, it could be lost.
                defaults.set(Date(), forKey: MoveToApplications.lastMoveKey)
                // No recorder, no update under way: nothing for a quit to ask.
                NSApp.terminate(nil)
                return true
            },
            tell: { title, text in
                let alert = NSAlert()
                alert.window.appearance = NSAppearance(named: .darkAqua)
                alert.messageText = title
                alert.informativeText = text
                alert.addButton(withTitle: "OK")
                alert.runModal()
            })
    }
}
#endif
