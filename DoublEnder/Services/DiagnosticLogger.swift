import Foundation
import Combine
import Accelerate
import OSLog

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

    /// The pinned lines, the buffer, and `systemLog` (`systemLogLines`), as
    /// plain text, for `dump`. Main thread.
    func exportText(systemLog: [String] = []) -> String {
        let format = { (line: Line) in "[\(line.stamp)] \(line.text)" }
        let pins = pinnedLines.map(format)
        let log = lines.map(format)
        guard !pins.isEmpty || !systemLog.isEmpty else { return log.joined(separator: "\n") }
        var sections: [String] = []
        if !pins.isEmpty { sections += ["-- PINNED --"] + pins }
        sections += ["-- LOG --"] + log
        if !systemLog.isEmpty { sections += ["-- SYSTEM LOG --"] + systemLog }
        return sections.joined(separator: "\n")
    }

    /// The subsystem every `Logger` in the app writes under.
    static let subsystem = "io.github.sevmorris.DoublEnder"

    /// The app's own entries in the unified log since this launch, the latest
    /// `limit` of them, for `dump`: everything its `Logger`s wrote (uploads,
    /// updates, recovery, the engine), which the ring never saw. Values the
    /// code marks private stay `<private>`. Reading this process's own log
    /// needs no entitlement. Slow (a second or so), so off the main thread.
    ///
    /// Debug and info entries may be missing: the system keeps those in
    /// memory only, and not always for long.
    static func systemLogLines(limit: Int = 2_000) -> [String] {
        let store: OSLogStore
        let entries: AnySequence<OSLogEntry>
        do {
            store = try OSLogStore(scope: .currentProcessIdentifier)
            entries = try store.getEntries(matching: NSPredicate(format: "subsystem BEGINSWITH %@", subsystem))
        } catch {
            return ["(the system log could not be read: \(error.localizedDescription))"]
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries {
            lines.append("[\(formatter.string(from: entry.date))] \(levelName(entry.level)) "
                         + "\(entry.category): \(entry.composedMessage)")
            if lines.count > limit * 2 { lines.removeFirst(lines.count - limit) }
        }
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        return lines
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        default: return "-"
        }
    }
}

/// The engine's `TLM` line: what the buffers of one interval held. Fed once
/// per buffer on the writer queue (`AudioEngine.recordTelemetry`).
///
/// Its levels are the samples' own, not the meter's. The meter reads no lower
/// than -36 dB, and `LevelMeter.dbFS` turns zero into that floor, so until
/// 2026-11-19 an input sending nothing but zeros (a denied microphone, a muted
/// interface) read "peak -36.0 · rms -36.0", louder than a quiet working one
/// at "rms -60". Zero now reads SILENT, and the RMS is the interval's, not
/// the last buffer's.
struct TelemetryWindow: Equatable {
    private(set) var buffers = 0
    private(set) var frames = 0
    /// The highest absolute sample, linear.
    private(set) var peak: Float = 0
    private var sumOfSquares: Double = 0
    private var measured = 0

    /// One buffer: its frame count, its mono mix (nil for a PCM format the
    /// mix cannot read), and that mix's peak, which the meter has already
    /// taken. One vDSP pass per buffer, for the sum of squares.
    mutating func add(frames: Int, mono: [Float]?, peak bufferPeak: Float) {
        buffers += 1
        self.frames += frames
        guard let mono, !mono.isEmpty else { return }
        var squares: Float = 0
        mono.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress!, 1, &squares, vDSP_Length($0.count)) }
        sumOfSquares += Double(squares)
        measured += mono.count
        peak = max(peak, bufferPeak)
    }

    /// The interval's RMS, linear; nil when no buffer could be read.
    var rms: Float? {
        measured > 0 ? Float((sumOfSquares / Double(measured)).squareRoot()) : nil
    }

    var line: String {
        let base = "TLM // \(buffers) buf · \(frames) fr"
        guard let rms else { return base + " · level unreadable (unsupported format)" }
        if peak == 0 { return base + " · SILENT (every sample zero)" }
        return base + " · peak \(Self.dBFS(peak)) · rms \(Self.dBFS(rms))"
    }

    static func dBFS(_ linear: Float) -> String {
        linear > 0 ? String(format: "%.1f dBFS", 20 * log10f(linear)) : "-inf dBFS"
    }
}
