import Foundation

/// Cloud: when to look for an update while the app is open.
///
/// Updates used to be found only at launch, so a guest who left the app open
/// for days was never updated. Now the app looks every few hours, and soon
/// after the Mac wakes; what it finds is downloaded and staged quietly, and
/// installed when the app quits (`UpdateCoordinator.startBackgroundUpdate`).
/// Nothing a guest sees changes until then.
enum BackgroundUpdateSchedule {
    /// How often the app asks itself whether a check is due. Timers stop while
    /// the Mac sleeps, so a long interval alone would drift.
    static let tick: TimeInterval = 15 * 60
    /// The longest the app goes between checks that got an answer.
    static let interval: TimeInterval = 4 * 60 * 60
    /// After a wake: at most this often, so a lid opened and closed all
    /// afternoon does not check each time.
    static let wakeGap: TimeInterval = 60 * 60
    /// The network takes a moment to come back after a wake.
    static let afterWake: TimeInterval = 30

    /// `lastCheck` is the last check that got an answer, nil when none has: a
    /// check that failed (offline) is tried again at the next tick.
    static func isDue(now: Date, lastCheck: Date?, afterWake: Bool) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= (afterWake ? wakeGap : interval)
    }
}
