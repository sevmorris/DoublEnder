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
        /// How the last take went (`TakeTally.summary`), removed when the
        /// next take is armed.
        case summary
    }

    struct Line: Identifiable, Equatable {
        let id: UInt64
        let stamp: String
        let level: Level
        let text: String
        /// How far into the take it was logged, or nil outside one.
        var offset: TimeInterval? = nil

        /// "+00:12:35.120": the offset, as long as `stamp`, for the console's
        /// time column. Nil outside a take.
        var offsetStamp: String? {
            offset.map(DiagnosticLogger.offsetStamp)
        }
    }

    /// One line of a command's answer, with the level it is shown at.
    struct Answer: Equatable {
        let text: String
        var level: Level = .info

        /// A section's heading, dimmed.
        static func heading(_ title: String) -> Answer {
            Answer(text: "── \(title) " + String(repeating: "─", count: max(3, 30 - title.count)), level: .system)
        }

        /// "LABEL .......... value", the label padded with dots to one width.
        static func row(_ label: String, _ value: String, level: Level = .info) -> Answer {
            Answer(text: DiagnosticLogger.dotted(label, width: 15) + " " + value, level: level)
        }
    }

    /// `label`, then dots out to `width`, with at least two.
    static func dotted(_ label: String, width: Int) -> String {
        label + " " + String(repeating: ".", count: max(2, width - label.count - 1))
    }

    /// "+00:12:35.120".
    static func offsetStamp(_ offset: TimeInterval) -> String {
        let millis = Int((max(0, offset) * 1000).rounded(.down))
        let s = millis / 1000
        return String(format: "+%02d:%02d:%02d.%03d", s / 3600, (s % 3600) / 60, s % 60, millis % 1000)
    }

    static let capacity = 500

    /// Main thread only.
    @Published private(set) var lines: [Line] = []
    /// The latest line of each pinned kind. Main thread only.
    @Published private(set) var pinned: [Pin: Line] = [:]

    /// When `shared` was made, which is when the engine was: about launch.
    let startedAt = Date()

    private let lock = NSLock()
    /// Each line with the take's start as it was logged, nil outside one.
    private var pending: [(Date, Level, String, Date?)] = []
    /// The running take's start (`beginTake`), under `lock`.
    private var takeStart: Date?
    /// Pins set (or, with nil, removed) since the last flush. Kept apart from
    /// `pending` so the ring's trimming can never drop one.
    private var pendingPins: [Pin: (Date, Level, String, Date?)?] = [:]
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
        pending.append((now, level, text, takeStart))
        if pending.count > Self.capacity { pending.removeFirst(pending.count - Self.capacity) }
        if let pin { pendingPins[pin] = .some((now, level, text, takeStart)) }
        let schedule = scheduleFlushLocked()
        lock.unlock()
        if schedule { DispatchQueue.main.async { self.flush() } }
    }

    /// Lines logged from now until `endTake` carry how far into the take they
    /// came (`Line.offset`), measured from `start`. Any queue.
    func beginTake(at start: Date = Date()) {
        lock.lock()
        takeStart = start
        lock.unlock()
    }

    /// Lines from now on carry no offset. Any queue.
    func endTake() {
        lock.lock()
        takeStart = nil
        lock.unlock()
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
            for (date, level, text, start) in batch {
                next.append(makeLine(date, level, text, start))
            }
            if next.count > Self.capacity { next.removeFirst(next.count - Self.capacity) }
            lines = next
        }
        if !pins.isEmpty {
            var next = pinned
            for (pin, entry) in pins {
                next[pin] = entry.map { makeLine($0.0, $0.1, $0.2, $0.3) }
            }
            pinned = next
        }
    }

    private func makeLine(_ date: Date, _ level: Level, _ text: String, _ takeStart: Date?) -> Line {
        nextID &+= 1
        return Line(id: nextID, stamp: formatter.string(from: date), level: level, text: text,
                    offset: takeStart.map { date.timeIntervalSince($0) })
    }

    /// The pinned lines, in `Pin` order. Main thread.
    var pinnedLines: [Line] {
        Pin.allCases.compactMap { pinned[$0] }
    }

    /// Empties the scrollback, with the lines logged but not yet shown, such
    /// as the `> clear` that asked for it. The pinned lines stay. Main thread.
    func clear() {
        lock.lock()
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        lines.removeAll()
    }

    /// `header` (`ServiceConsole.dumpHeader`), the pinned lines, the buffer,
    /// and `systemLog` (`systemLogLines`), as plain text, for `dump`. A line
    /// logged during a take keeps both its time and its offset into the take.
    /// Main thread.
    func exportText(header: [String] = [], systemLog: [String] = []) -> String {
        let format = { (line: Line) in
            "[\(line.stamp)\(line.offsetStamp.map { " \($0)" } ?? "")] \(line.text)"
        }
        let pins = pinnedLines.map(format)
        let log = lines.map(format)
        guard !pins.isEmpty || !systemLog.isEmpty || !header.isEmpty else { return log.joined(separator: "\n") }
        var sections: [String] = header
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

/// What the input delivered over one interval of a take, for the Service
/// Monitor's `LEVEL` line. Fed once per buffer on the writer queue
/// (`AudioEngine.recordTelemetry`), and taken whole every 5 s on the main
/// thread (`AudioEngine.drainTelemetry`), which also measures how long the
/// interval really was, so an interval in which no buffer came still has a
/// line.
///
/// Its levels are the samples' own, not the meter's. The meter reads no lower
/// than -36 dB, and `LevelMeter.dbFS` turns zero into that floor, so until
/// 2026-11-19 an input sending nothing but zeros (a denied microphone, a muted
/// interface) read "peak -36.0 · rms -36.0", louder than a quiet working one
/// at "rms -60". Zero reads SILENT, and the RMS is the interval's, not the
/// last buffer's.
struct TelemetryWindow: Equatable {
    private(set) var buffers = 0
    private(set) var frames = 0
    /// Seconds of audio the buffers held, from their own sample rate.
    private(set) var audioSeconds: Double = 0
    /// The highest absolute sample, linear.
    private(set) var peak: Float = 0
    /// Buffers the writer was not ready for, and dropped.
    private(set) var droppedBuffers = 0
    /// Buffers the writer refused.
    private(set) var failedWrites = 0
    private var sumOfSquares: Double = 0
    private var measured = 0

    /// One buffer: its frame count, its length in seconds, its mono mix (nil
    /// for a PCM format the mix cannot read), and that mix's peak, which the
    /// meter has already taken. One vDSP pass per buffer, for the sum of
    /// squares.
    mutating func add(frames: Int, seconds: Double, mono: [Float]?, peak bufferPeak: Float) {
        buffers += 1
        self.frames += frames
        audioSeconds += seconds
        guard let mono, !mono.isEmpty else { return }
        var squares: Float = 0
        mono.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress!, 1, &squares, vDSP_Length($0.count)) }
        sumOfSquares += Double(squares)
        measured += mono.count
        peak = max(peak, bufferPeak)
    }

    mutating func noteDroppedBuffer() { droppedBuffers += 1 }
    mutating func noteFailedWrite() { failedWrites += 1 }

    /// The interval's RMS, linear; nil when no buffer could be read.
    var rms: Float? {
        measured > 0 ? Float((sumOfSquares / Double(measured)).squareRoot()) : nil
    }

    /// What the level says, in a word.
    enum Verdict: String {
        /// No buffer arrived at all.
        case noAudio = "NO AUDIO"
        /// Buffers came, in a format the mix cannot read.
        case unreadable = "UNREADABLE"
        /// Every sample was zero: a denied microphone, a muted interface.
        case silent = "SILENT"
        /// A sample reached -0.1 dBFS: the take is clipping.
        case clipped = "CLIP"
        /// Within 3 dB of full scale.
        case hot = "HOT"
        /// Nothing above -40 dBFS: nobody spoke on this side.
        case quiet = "QUIET"
        case ok = "OK"

        var isProblem: Bool { self == .noAudio || self == .silent || self == .clipped }
    }

    static let clipLinear: Float = 0.9886   // -0.1 dBFS
    static let hotLinear: Float = 0.7079    // -3 dBFS
    static let quietLinear: Float = 0.01    // -40 dBFS

    var verdict: Verdict {
        if buffers == 0 { return .noAudio }
        guard rms != nil else { return .unreadable }
        if peak == 0 { return .silent }
        if peak >= Self.clipLinear { return .clipped }
        if peak >= Self.hotLinear { return .hot }
        if peak < Self.quietLinear { return .quiet }
        return .ok
    }

    /// Audio the input should have delivered in `wallSeconds` and did not,
    /// past a half-second allowance for buffers in flight at either end; nil
    /// when it kept up.
    func shortfall(wallSeconds: Double) -> Double? {
        let missing = wallSeconds - audioSeconds
        return missing > Self.shortfallAllowance ? missing : nil
    }

    static let shortfallAllowance = 0.5

    /// True when the line is a warning: no audio, silence, clipping, audio
    /// missing, or buffers dropped or refused.
    func isProblem(wallSeconds: Double) -> Bool {
        verdict.isProblem || shortfall(wallSeconds: wallSeconds) != nil || droppedBuffers > 0 || failedWrites > 0
    }

    /// The `LEVEL` line for an interval of `wallSeconds`, with the file and
    /// the disk where `disk` has them.
    func line(wallSeconds: Double, disk: DiskReading? = nil) -> String {
        var parts: [String]
        switch verdict {
        case .noAudio: parts = ["LEVEL NO AUDIO (no buffers arrived)"]
        case .unreadable: parts = ["LEVEL UNREADABLE (unsupported format)"]
        case .silent: parts = ["LEVEL SILENT (every sample zero)"]
        default:
            parts = ["LEVEL pk \(Self.dB(peak)) · avg \(Self.dB(rms ?? 0)) dBFS · \(verdict.rawValue)"]
        }
        var audio = String(format: "audio %.1f s / %.1f s", audioSeconds, wallSeconds)
        if shortfall(wallSeconds: wallSeconds) != nil { audio += " INPUT DROPPING" }
        parts.append(audio)
        if droppedBuffers > 0 {
            parts.append("\(droppedBuffers) buffer\(droppedBuffers == 1 ? "" : "s") DROPPED (writer behind)")
        }
        if failedWrites > 0 {
            parts.append("\(failedWrites) write\(failedWrites == 1 ? "" : "s") FAILED")
        }
        if let disk { parts.append(disk.text) }
        return parts.joined(separator: " · ")
    }

    /// "-12.3", or "-inf".
    static func dB(_ linear: Float) -> String {
        linear > 0 ? String(format: "%.1f", 20 * log10f(linear)) : "-inf"
    }

    static func dBFS(_ linear: Float) -> String {
        dB(linear) + " dBFS"
    }
}

/// The take's file and the disk under it, for the `LEVEL` line and the live
/// status block.
struct DiskReading: Equatable {
    /// The file so far.
    var fileBytes: Int64
    /// Free space on the recordings volume, nil when it can't be read.
    var freeBytes: Int64?
    /// Free space the disk watch keeps back: the take stops when it is reached
    /// (`DiskSpaceChecker.minimumFreeBytes`).
    var reserveBytes: Int64 = 0
    /// The take's average write rate so far, nil before it can be measured.
    var bytesPerSecond: Double?

    /// How long the free space lasts at `bytesPerSecond`, before the disk
    /// watch stops the take.
    var secondsLeft: Double? {
        guard let freeBytes, let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return Double(max(0, freeBytes - reserveBytes)) / bytesPerSecond
    }

    /// "file 412.3 MB · free 393 GB (~30 h)".
    var text: String {
        var text = "file \(ServiceFormat.bytes(fileBytes))"
        guard let freeBytes else { return text + " · free ?" }
        text += " · free \(ServiceFormat.bytes(freeBytes))"
        if let left = secondsLeft { text += " (\(ServiceFormat.timeLeft(left)))" }
        return text
    }
}

/// How a take went, interval by interval (`TelemetryWindow`), for the
/// summary pinned when it ends. Main thread.
struct TakeTally: Equatable {
    private(set) var intervals = 0
    private(set) var silentIntervals = 0
    private(set) var clippedIntervals = 0
    /// Intervals the input fell short in, or delivered nothing.
    private(set) var shortIntervals = 0
    private(set) var droppedBuffers = 0
    private(set) var failedWrites = 0
    /// The take's highest sample, linear.
    private(set) var peak: Float = 0

    mutating func add(_ window: TelemetryWindow, wallSeconds: Double) {
        intervals += 1
        switch window.verdict {
        case .silent: silentIntervals += 1
        case .clipped: clippedIntervals += 1
        default: break
        }
        if window.shortfall(wallSeconds: wallSeconds) != nil { shortIntervals += 1 }
        droppedBuffers += window.droppedBuffers
        failedWrites += window.failedWrites
        peak = max(peak, window.peak)
    }

    var hasProblems: Bool {
        silentIntervals + clippedIntervals + shortIntervals + droppedBuffers + failedWrites > 0
    }

    /// The `TAKE` line: how long, how big, how it ended and why, and what went
    /// wrong along the way. A warning when the file was not saved whole, or
    /// anything did go wrong.
    func summary(seconds: Int, fileBytes: Int64?, end: SessionDiagnostics.TakeEnd, cause: String,
                 interruptions: Int, voice: VoiceDetector.Status) -> DiagnosticLogger.Answer {
        var parts = ["TAKE // \(TimeInterval(seconds).hhmmss)"]
        if let fileBytes { parts.append(ServiceFormat.bytes(fileBytes)) }
        parts.append(Self.endText(end) + ", " + Self.causeText(cause))
        parts.append("peak \(TelemetryWindow.dBFS(peak))")
        parts.append(Self.count(droppedBuffers, "dropped"))
        if failedWrites > 0 { parts.append(Self.count(failedWrites, "failed writes")) }
        parts.append(Self.count(shortIntervals, "short"))
        parts.append(Self.count(silentIntervals, "silent"))
        parts.append(Self.count(clippedIntervals, "clipped"))
        parts.append(interruptions == 1 ? "1 interruption" : "\(interruptions) interruptions")
        parts.append(voice.heard ? "voice heard" : "NO VOICE HEARD")
        let warn = end != .saved || hasProblems || interruptions > 0 || !voice.heard
        return DiagnosticLogger.Answer(text: parts.joined(separator: " · "), level: warn ? .warn : .event)
    }

    private static func count(_ n: Int, _ what: String) -> String {
        n == 0 ? "0 \(what)" : "\(n) \(what.uppercased())"
    }

    static func endText(_ end: SessionDiagnostics.TakeEnd) -> String {
        switch end {
        case .saved: return "SAVED"
        case .recovered: return "WRITER FAILED, rebuilding from the sidecar"
        case .recoverAtLaunch: return "WRITER FAILED, the sidecar waits for the next launch"
        case .noAudio: return "NO AUDIO CAPTURED"
        case .failed: return "FAILED, nothing to recover"
        }
    }

    /// `SessionDiagnostics.takeCause` in words.
    static func causeText(_ cause: String) -> String {
        switch cause {
        case "user": return "stopped in the app"
        case "remote": return "stopped by the producer"
        case "diskSpace": return "stopped: disk nearly full"
        case "engine": return "stopped by the engine"
        default:
            return "stopped: " + (CaptureFailure(rawValue: cause)?.serviceDescription ?? cause)
        }
    }
}

/// Sizes and times as the Service Monitor writes them.
enum ServiceFormat {
    /// "812 KB", "412.3 MB", "1.93 GB", "393 GB", in units of 1,024.
    static func bytes(_ bytes: Int64) -> String {
        let b = Double(max(0, bytes))
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        if b < mb { return String(format: "%.0f KB", b / kb) }
        if b < gb { return String(format: "%.1f MB", b / mb) }
        if b < 100 * gb { return String(format: "%.2f GB", b / gb) }
        return String(format: "%.0f GB", b / gb)
    }

    /// "~271 days", "~30 h", "~45 min", "<1 min".
    static func timeLeft(_ seconds: Double) -> String {
        if seconds < 60 { return "<1 min" }
        if seconds < 2 * 3600 { return "~\(Int(seconds / 60)) min" }
        if seconds < 100 * 3600 { return "~\(Int(seconds / 3600)) h" }
        return "~\(Int(seconds / 86_400)) days"
    }

    /// "4.6 MB/min".
    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond * 60)) + "/min"
    }

    /// A transport as `SessionDiagnostics.transportName` names it, in words.
    static func transport(_ name: String) -> String {
        switch name {
        case "builtIn": return "built-in"
        case "usb": return "USB"
        case "bluetooth": return "Bluetooth"
        case "bluetoothLE": return "Bluetooth LE"
        case "thunderbolt": return "Thunderbolt"
        case "pci": return "PCI"
        case "firewire": return "FireWire"
        case "hdmi": return "HDMI"
        case "displayPort": return "DisplayPort"
        case "airPlay": return "AirPlay"
        case "avb": return "AVB"
        case "continuity": return "iPhone (Continuity)"
        default: return name
        }
    }
}
