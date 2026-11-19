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
final class DiagnosticLogger: ObservableObject {
    static let shared = DiagnosticLogger()

    enum Level { case info, event, warn, input, system }

    struct Line: Identifiable, Equatable {
        let id: UInt64
        let stamp: String
        let level: Level
        let text: String
    }

    static let capacity = 500

    /// Main thread only.
    @Published private(set) var lines: [Line] = []

    private let lock = NSLock()
    private var pending: [(Date, Level, String)] = []
    private var flushScheduled = false
    private var nextID: UInt64 = 0
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {}

    func log(_ text: String, level: Level = .info) {
        let now = Date()
        lock.lock()
        pending.append((now, level, text))
        if pending.count > Self.capacity { pending.removeFirst(pending.count - Self.capacity) }
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        if schedule { DispatchQueue.main.async { self.flush() } }
    }

    private func flush() {
        lock.lock()
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        flushScheduled = false
        lock.unlock()
        guard !batch.isEmpty else { return }
        var next = lines
        for (date, level, text) in batch {
            nextID &+= 1
            next.append(Line(id: nextID, stamp: formatter.string(from: date), level: level, text: text))
        }
        if next.count > Self.capacity { next.removeFirst(next.count - Self.capacity) }
        lines = next
    }

    /// Main thread.
    func clear() {
        lines.removeAll()
    }

    /// The buffer as plain text, for `dump`. Main thread.
    func exportText() -> String {
        lines.map { "[\($0.stamp)] \($0.text)" }.joined(separator: "\n")
    }
}
