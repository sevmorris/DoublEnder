import Foundation
import Combine

/// In-app telemetry for the hidden Service Monitor (About → triple-click or
/// ⌥-click the icon). A ring buffer of at most `capacity` lines, so memory
/// stays flat however long the app runs.
///
/// `log` is safe from any queue and cheap enough for the writer queue: it
/// takes a lock, appends a tuple, and schedules at most one main-queue flush
/// per batch. Formatting and publishing happen on main. Nothing here ever
/// waits on the main thread, so a blocked UI cannot stall capture.
///
/// A take adds two lines every 5 seconds, so the ring holds about the last 20
/// minutes of one, and a longer take's handshake would scroll out before it
/// ends. The facts support needs most are therefore also pinned (`Pin`): the
/// latest line of each kind is kept outside the ring, shown above it and put
/// first in `dump`.
final class DiagnosticLogger: ObservableObject {
    static let shared = DiagnosticLogger()

    enum Level { case info, event, warn, input, system }

    /// A kind of line whose latest is kept outside the ring, in this order.
    enum Pin: CaseIterable {
        /// The capture session's handshake with the input, or its failure.
        case input
        /// A low-quality input (≤16 kHz), while the input is one.
        case inputWarning
        /// The writer opening on the take's first buffer, with its format.
        case writer
        /// The take's start: its file and format.
        case take
    }

    struct Line: Identifiable, Equatable {
        let id: UInt64
        let stamp: String
        let level: Level
        let text: String
    }

    static let capacity = 500

    /// Main thread only.
    @Published private(set) var lines: [Line] = []
    /// The latest line of each pinned kind. Main thread only.
    @Published private(set) var pinned: [Pin: Line] = [:]

    private let lock = NSLock()
    private var pending: [(Date, Level, String)] = []
    /// Pins set (or, with nil, removed) since the last flush. Kept apart from
    /// `pending` so the ring's trimming can never drop one.
    private var pendingPins: [Pin: (Date, Level, String)?] = [:]
    private var flushScheduled = false
    private var nextID: UInt64 = 0
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// `shared` in the app; a test makes its own.
    init() {}

    /// Adds a line. With `pin`, it also becomes the pinned line of that kind,
    /// replacing the one before.
    func log(_ text: String, level: Level = .info, pin: Pin? = nil) {
        let now = Date()
        lock.lock()
        pending.append((now, level, text))
        if pending.count > Self.capacity { pending.removeFirst(pending.count - Self.capacity) }
        if let pin { pendingPins[pin] = .some((now, level, text)) }
        let schedule = scheduleFlushLocked()
        lock.unlock()
        if schedule { DispatchQueue.main.async { self.flush() } }
    }

    /// Removes the pinned line of that kind, if there is one.
    func unpin(_ pin: Pin) {
        lock.lock()
        pendingPins[pin] = .some(nil)
        let schedule = scheduleFlushLocked()
        lock.unlock()
        if schedule { DispatchQueue.main.async { self.flush() } }
    }

    private func scheduleFlushLocked() -> Bool {
        let schedule = !flushScheduled
        flushScheduled = true
        return schedule
    }

    private func flush() {
        lock.lock()
        let batch = pending
        let pins = pendingPins
        pending.removeAll(keepingCapacity: true)
        pendingPins.removeAll()
        flushScheduled = false
        lock.unlock()
        if !batch.isEmpty {
            var next = lines
            for (date, level, text) in batch {
                next.append(makeLine(date, level, text))
            }
            if next.count > Self.capacity { next.removeFirst(next.count - Self.capacity) }
            lines = next
        }
        if !pins.isEmpty {
            var next = pinned
            for (pin, entry) in pins {
                next[pin] = entry.map { makeLine($0.0, $0.1, $0.2) }
            }
            pinned = next
        }
    }

    private func makeLine(_ date: Date, _ level: Level, _ text: String) -> Line {
        nextID &+= 1
        return Line(id: nextID, stamp: formatter.string(from: date), level: level, text: text)
    }

    /// The pinned lines, in `Pin` order. Main thread.
    var pinnedLines: [Line] {
        Pin.allCases.compactMap { pinned[$0] }
    }

    /// Empties the scrollback. The pinned lines stay. Main thread.
    func clear() {
        lines.removeAll()
    }

    /// The pinned lines and then the buffer, as plain text, for `dump`. Main
    /// thread.
    func exportText() -> String {
        let format = { (line: Line) in "[\(line.stamp)] \(line.text)" }
        let pins = pinnedLines.map(format)
        let log = lines.map(format)
        guard !pins.isEmpty else { return log.joined(separator: "\n") }
        return (["-- PINNED --"] + pins + ["-- LOG --"] + log).joined(separator: "\n")
    }
}
