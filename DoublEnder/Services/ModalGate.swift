import AppKit

/// The one way a modal dialog of the app's opens.
///
/// The recorder, the quit intercept, crash recovery and the updater each put up
/// dialogs, from timers, device callbacks and network replies that know nothing
/// of one another. A flag private to the view model kept its own alerts from
/// stacking, and nothing else: a USB device plugged in while an update's dialog
/// was up got its prompt on top, and an update could replace the app under a
/// guest who was typing their name. Through here, every dialog counts as
/// something the app is in the middle of (`AppActivity`), an offer that can
/// wait is dropped when another dialog is up, and nothing opens once an update
/// has begun to replace the app.
///
/// Main thread only.
enum ModalGate {
    enum Priority {
        /// It has to be seen, so it opens even over another dialog.
        case required
        /// An offer the user can do without, such as switching to a USB input
        /// that also sits in the picker. Dropped while another dialog is up.
        case prompt
    }

    private(set) static var depth = 0

    static var isPresenting: Bool { depth > 0 }

    /// Runs `body`, which runs a modal session, and returns its result. Returns
    /// nil, without running it, for a prompt when a dialog is already up and for
    /// anything while an update is replacing the app.
    @discardableResult
    static func run<T>(_ priority: Priority = .required, activity: AppActivity = .shared,
                       _ body: () -> T) -> T? {
        assert(Thread.isMainThread)
        guard !activity.isCommittingUpdate else { return nil }
        if priority == .prompt && isPresenting { return nil }
        depth += 1
        activity.begin(.modal)
        defer {
            depth -= 1
            activity.end(.modal)
        }
        return body()
    }

    /// For main actor code in an async context, which is to say inside a main
    /// actor task. Run from there, a modal stops the main queue until it closes
    /// (see `MainRunLoop`), and with it an upload's progress, the engine's
    /// disconnect handling and the producer's remote stop. This runs the dialog
    /// from the run loop instead, so the queue stays live under it.
    ///
    /// `suppressed` is asked on that same pass of the run loop, with nothing in
    /// between it and the dialog: a caller that must not open a dialog over a
    /// take passes the check here, where a take cannot start in the gap.
    @MainActor
    static func runFromRunLoop<T>(_ priority: Priority = .required, activity: AppActivity = .shared,
                                  unless suppressed: @escaping @MainActor () -> Bool = { false },
                                  _ body: @escaping @MainActor () -> T) async -> T? {
        await MainRunLoop.run {
            if suppressed() { return nil }
            return run(priority, activity: activity) { body() }
        }
    }
}
