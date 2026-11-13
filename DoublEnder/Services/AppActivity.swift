import Foundation

/// What the app is in the middle of, kept in one place.
///
/// Two things need to know: a quit, which asks before it cuts a take or an
/// upload short, and an update, which replaces the app and relaunches it, and
/// so waits for everything. Until this existed each had its own idea of "busy"
/// (the quit intercept in AppDelegate, `recorderIsBusy` in UpdateChecker), an
/// update was safe only while the two happened to agree, and neither knew that
/// a guest typing their name, or a crashed take being converted, was work too.
///
/// Main thread only, like the recorder it reads.
final class AppActivity {
    static let shared = AppActivity()

    enum Blocker: Hashable, CaseIterable {
        /// A take, from RECORD until its file is closed.
        case recording
        /// Cloud: a finished take on its way up.
        case uploading
        /// A crashed take's sidecar being converted to a WAV.
        case recovering
        /// A dialog of the app's is up: someone is in the middle of answering.
        case modal
    }

    /// What a quit has to ask about before it goes ahead.
    enum QuitQuestion: Equatable {
        case recording
        case uploading
    }

    /// The recorder's blockers. nil until the recorder exists, and it stays nil
    /// while Cloud's launch update runs: asking must never build the recorder,
    /// which would bring up the capture session and the microphone prompt.
    var recorder: (() -> Set<Blocker>)?

    private var held: [Blocker: Int] = [:]

    /// True from the moment an update starts to replace the app. Until the
    /// process ends, or the replacement fails, nothing new may start: no take,
    /// no dialog.
    private(set) var isCommittingUpdate = false

    init() {}

    var blockers: Set<Blocker> {
        var all = Set(held.compactMap { $0.value > 0 ? $0.key : nil })
        if let recorder { all.formUnion(recorder()) }
        return all
    }

    /// True while replacing the app and relaunching it would cut something short.
    var blocksRelaunch: Bool { !blockers.isEmpty }

    /// True while the app does work that a download, a disk image being
    /// mounted and a copy being made must not compete with: a take writing to
    /// the disk, an upload using the network, a recovery converting a file. A
    /// dialog does not count: it does no work of its own.
    var blocksHeavyWork: Bool { !blockers.isDisjoint(with: [.recording, .uploading, .recovering]) }

    /// Drawn from `blockers`, so whenever a quit would ask, a relaunch is
    /// blocked: an update can never reach the question, which it could not
    /// answer.
    var quitQuestion: QuitQuestion? {
        let current = blockers
        if current.contains(.recording) { return .recording }
        if current.contains(.uploading) { return .uploading }
        return nil
    }

    func begin(_ blocker: Blocker) {
        assert(Thread.isMainThread)
        held[blocker, default: 0] += 1
    }

    func end(_ blocker: Blocker) {
        assert(Thread.isMainThread)
        held[blocker] = max(0, (held[blocker] ?? 0) - 1)
    }

    func beginCommittingUpdate() {
        assert(Thread.isMainThread)
        isCommittingUpdate = true
    }

    /// The replacement failed and the installed app is as it was.
    func endCommittingUpdate() {
        assert(Thread.isMainThread)
        isCommittingUpdate = false
    }
}
