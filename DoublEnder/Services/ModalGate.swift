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
/// wait does not open over another dialog, and nothing opens once an update
/// has begun to replace the app.
///
/// An offer that does not open is not lost: whoever makes it keeps it and tries
/// again when `didChange` says a dialog has closed (`WaitingOffers`). 2.8.4
/// dropped it instead, and a guest whose launch had a dialog to show (a crashed
/// take to recover, an upload to finish) was never offered their USB microphone.
///
/// Main thread only.
enum ModalGate {
    enum Priority {
        /// It has to be seen, so it opens even over another dialog.
        case required
        /// An offer the user can do without for a moment, such as switching to
        /// a USB input that also sits in the picker. It does not open while
        /// another dialog is up, unless that dialog admits offers.
        case prompt
    }

    /// Posted on the main thread when a dialog has closed.
    static let didChange = Notification.Name("io.github.sevmorris.DoublEnder.ModalGate.didChange")

    /// The dialogs that are up, outermost first: whether each admits an offer
    /// over it.
    private static var open: [Bool] = []

    static var depth: Int { open.count }

    static var isPresenting: Bool { !open.isEmpty }

    /// True when an offer would open now: no dialog is up, or only ones that
    /// admit offers, and no update is replacing the app.
    static func canOpenOffer(activity: AppActivity = .shared) -> Bool {
        !activity.isCommittingUpdate && open.allSatisfy { $0 }
    }

    /// Runs `body`, which runs a modal session, and returns its result. Returns
    /// nil, without running it, for a prompt that cannot open now
    /// (`canOpenOffer`) and for anything while an update is replacing the app.
    ///
    /// `admitsOffers` is for a dialog the guest answers on the way to a take,
    /// where an input that has just appeared is worth asking about at once: the
    /// name prompt. An offer that waited for it to close would arrive with the
    /// take already running on the other input.
    @discardableResult
    static func run<T>(_ priority: Priority = .required, activity: AppActivity = .shared,
                       admitsOffers: Bool = false, _ body: () -> T) -> T? {
        assert(Thread.isMainThread)
        guard !activity.isCommittingUpdate else { return nil }
        if priority == .prompt && !canOpenOffer(activity: activity) { return nil }
        open.append(admitsOffers)
        activity.begin(.modal)
        defer {
            open.removeLast()
            activity.end(.modal)
            NotificationCenter.default.post(name: didChange, object: nil)
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
