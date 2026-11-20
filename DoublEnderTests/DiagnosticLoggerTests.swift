import XCTest
import OSLog
@testable import DoublEnder

/// The Service Monitor's log. Each test makes its own logger, never `shared`.
final class DiagnosticLoggerTests: XCTestCase {

    /// `log` publishes on a later pass of the main queue; this waits for it.
    private func flushed(_ logger: DiagnosticLogger, until done: () -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !done() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(done(), "the log never flushed", file: file, line: line)
    }

    /// The ring keeps the last `capacity` lines and no more.
    func testTheRingKeepsTheLastLines() {
        let logger = DiagnosticLogger()
        for i in 1...(DiagnosticLogger.capacity + 100) { logger.log("line \(i)") }
        flushed(logger) { logger.lines.last?.text == "line \(DiagnosticLogger.capacity + 100)" }
        XCTAssertEqual(logger.lines.count, DiagnosticLogger.capacity)
        XCTAssertEqual(logger.lines.first?.text, "line 101")
    }

    /// A take adds about a line every 5 seconds, so two hours of one is 1,440 lines,
    /// and the handshake at its start used to have scrolled out by its end.
    /// Pinned, it stays.
    func testTheHandshakeSurvivesALongTake() {
        let logger = DiagnosticLogger()
        logger.log("HANDSHAKE // USB Mic · 48000 Hz", level: .event, pin: .input)
        logger.log("STATE IDLE -> ARMED // Ada.m4a [AAC]", level: .event, pin: .take)
        for i in 1...1_440 { logger.log("LEVEL // \(i)") }
        flushed(logger) { logger.lines.last?.text == "LEVEL // 1440" }

        XCTAssertFalse(logger.lines.contains { $0.text.hasPrefix("HANDSHAKE") }, "the ring kept it anyway")
        XCTAssertEqual(logger.pinnedLines.map(\.text),
                       ["HANDSHAKE // USB Mic · 48000 Hz", "STATE IDLE -> ARMED // Ada.m4a [AAC]"])
        XCTAssertEqual(logger.pinned[.input]?.level, .event)
    }

    /// The latest of each kind replaces the one before, `unpin` removes it,
    /// and the pinned lines come in `Pin` order whatever order they came in.
    func testTheLatestOfEachKindIsPinned() {
        let logger = DiagnosticLogger()
        logger.log("STATE IDLE -> ARMED // One.m4a", pin: .take)
        logger.log("LOW-QUALITY INPUT", level: .warn, pin: .inputWarning)
        logger.log("HANDSHAKE // AirPods · 16000 Hz", pin: .input)
        logger.log("HANDSHAKE // USB Mic · 48000 Hz", pin: .input)
        logger.unpin(.inputWarning)
        logger.log("unpinned")
        flushed(logger) { logger.lines.last?.text == "unpinned" }

        XCTAssertEqual(logger.pinnedLines.map(\.text),
                       ["HANDSHAKE // USB Mic · 48000 Hz", "STATE IDLE -> ARMED // One.m4a"])
        XCTAssertEqual(logger.lines.count, 5, "a pinned line is in the scrollback too")
    }

    /// `clear` empties the scrollback and keeps the pinned lines; `dump`
    /// puts them first.
    func testClearKeepsThePinnedLinesAndDumpLeadsWithThem() {
        let logger = DiagnosticLogger()
        logger.log("HANDSHAKE // USB Mic", pin: .input)
        logger.log("TLM // 1")
        flushed(logger) { logger.lines.count == 2 }

        let dump = logger.exportText().split(separator: "\n").map { $0.replacing(#/^\[[^\]]*\] /#, with: "") }
        XCTAssertEqual(dump, ["-- PINNED --", "HANDSHAKE // USB Mic", "-- LOG --", "HANDSHAKE // USB Mic", "TLM // 1"])

        logger.clear()
        XCTAssertTrue(logger.lines.isEmpty)
        XCTAssertEqual(logger.pinnedLines.map(\.text), ["HANDSHAKE // USB Mic"])

        let plain = DiagnosticLogger()
        plain.log("TLM // 1")
        flushed(plain) { plain.lines.count == 1 }
        XCTAssertFalse(plain.exportText().contains("PINNED"), "no header with nothing pinned")
    }

    /// `clear` also drops what was logged but not yet shown, so the `> clear`
    /// that asked for it does not come back on the empty screen.
    func testClearLeavesAnEmptyScreen() {
        let logger = DiagnosticLogger()
        logger.log("TLM // 1")
        flushed(logger) { logger.lines.count == 1 }
        logger.log("> clear")
        logger.clear()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(logger.lines.isEmpty, "\(logger.lines.map(\.text))")

        logger.log("after")
        flushed(logger) { logger.lines.count == 1 }
        XCTAssertEqual(logger.lines.first?.text, "after")
    }

    /// With the system log, `dump` gets a third section, and the log keeps its
    /// header with nothing pinned.
    func testDumpEndsWithTheSystemLog() {
        let logger = DiagnosticLogger()
        logger.log("TLM // 1")
        flushed(logger) { logger.lines.count == 1 }
        let dump = logger.exportText(systemLog: ["[00:00:00.000] NOTICE AudioEngine: hello"])
            .split(separator: "\n").map { $0.replacing(#/^\[[^\]]*\] /#, with: "") }
        XCTAssertEqual(dump, ["-- LOG --", "TLM // 1", "-- SYSTEM LOG --", "NOTICE AudioEngine: hello"])
    }

    /// Between `beginTake` and `endTake` a line carries how far into the
    /// take it came, and `dump` keeps both times.
    func testLinesInATakeCountFromItsStart() {
        let logger = DiagnosticLogger()
        logger.log("before")
        logger.beginTake(at: Date().addingTimeInterval(-754.25))
        logger.log("during")
        logger.endTake()
        logger.log("after")
        flushed(logger) { logger.lines.count == 3 }

        XCTAssertNil(logger.lines[0].offset)
        XCTAssertNil(logger.lines[2].offset)
        let offset = try? XCTUnwrap(logger.lines[1].offset)
        XCTAssertEqual(offset ?? 0, 754.25, accuracy: 1)
        XCTAssertTrue(logger.lines[1].offsetStamp?.hasPrefix("+00:12:3") ?? false, logger.lines[1].offsetStamp ?? "nil")
        XCTAssertEqual(logger.lines[1].offsetStamp?.count, logger.lines[1].stamp.count + 1)

        let dump = logger.exportText().split(separator: "\n")
        XCTAssertNotNil(dump[1].wholeMatch(of: #/\[\d\d:\d\d:\d\d\.\d{3} \+00:12:3\d\.\d{3}\] during/#), String(dump[1]))
        XCTAssertNotNil(dump[0].wholeMatch(of: #/\[\d\d:\d\d:\d\d\.\d{3}\] before/#), String(dump[0]))
    }

    /// The summary pins last, and `dump` leads with the header.
    func testTheSummaryPinsLastUnderTheHeader() {
        let logger = DiagnosticLogger()
        logger.log("TAKE // 00:00:05", pin: .summary)
        logger.log("STATE ARMED -> RECORDING // One.wav", pin: .take)
        logger.log("HANDSHAKE // USB Mic", pin: .input)
        flushed(logger) { logger.lines.count == 3 }
        XCTAssertEqual(logger.pinnedLines.map(\.text),
                       ["HANDSHAKE // USB Mic", "STATE ARMED -> RECORDING // One.wav", "TAKE // 00:00:05"])
        let dump = logger.exportText(header: ["-- DoublEnder 1.0 (1) --"]).split(separator: "\n")
        XCTAssertEqual(dump.first, "-- DoublEnder 1.0 (1) --")
        XCTAssertEqual(dump.dropFirst().first, "-- PINNED --")
    }

    /// `status`-style rows line their values up.
    func testRowsLineUp() {
        XCTAssertEqual(DiagnosticLogger.Answer.row("FREE", "1 GB").text, "FREE .......... 1 GB")
        XCTAssertEqual(DiagnosticLogger.Answer.row("OUTPUT FORMAT", "WAV").text, "OUTPUT FORMAT .. WAV")
        XCTAssertEqual(DiagnosticLogger.Answer.heading("DISK").level, .system)
    }

    /// The app's own `Logger` output comes back from the unified log.
    func testTheSystemLogHoldsTheAppsOwnEntries() {
        let token = UUID().uuidString
        Logger(subsystem: DiagnosticLogger.subsystem, category: "Tests").error("dump probe \(token, privacy: .public)")
        let deadline = Date().addingTimeInterval(10)
        var found = false
        while !found && Date() < deadline {
            found = DiagnosticLogger.systemLogLines().contains { $0.contains(token) && $0.contains("ERROR Tests:") }
        }
        XCTAssertTrue(found, "the probe never showed up in the system log")
    }
}

/// The `LEVEL` line: the levels, the verdict, and audio against time.
final class TelemetryWindowTests: XCTestCase {

    private func window(_ sample: Float, buffers: Int = 1, frames: Int = 480, seconds: Double = 0.01) -> TelemetryWindow {
        var window = TelemetryWindow()
        for _ in 0..<buffers {
            window.add(frames: frames, seconds: seconds, mono: [Float](repeating: sample, count: frames), peak: abs(sample))
        }
        return window
    }

    /// Zeros are SILENT, not the meter's -36 dB floor, which a quiet working
    /// input reads below.
    func testDigitalSilenceSaysSo() {
        let silent = window(0)
        XCTAssertEqual(silent.verdict, .silent)
        XCTAssertEqual(silent.line(wallSeconds: 0.01), "LEVEL SILENT (every sample zero) · audio 0.0 s / 0.0 s")
        XCTAssertTrue(silent.isProblem(wallSeconds: 0.01))

        let quiet = window(0.001)
        XCTAssertEqual(quiet.verdict, .quiet)
        XCTAssertEqual(quiet.line(wallSeconds: 0.01), "LEVEL pk -60.0 · avg -60.0 dBFS · QUIET · audio 0.0 s / 0.0 s")
        XCTAssertFalse(quiet.isProblem(wallSeconds: 0.01), "nobody speaking is not a fault")
    }

    /// The RMS is the interval's: a loud buffer then a quiet one is not the
    /// quiet one's level.
    func testTheRMSCoversTheWholeInterval() {
        var window = TelemetryWindow()
        window.add(frames: 100, seconds: 0.5, mono: [Float](repeating: 0.5, count: 100), peak: 0.5)
        window.add(frames: 100, seconds: 0.5, mono: [Float](repeating: 0, count: 100), peak: 0)
        XCTAssertEqual(window.rms ?? 0, Float(0.5 / 2.0.squareRoot()), accuracy: 1e-6)
        XCTAssertEqual(window.peak, 0.5)
        XCTAssertEqual(window.frames, 200)
        XCTAssertEqual(window.audioSeconds, 1)
        XCTAssertEqual(window.line(wallSeconds: 1), "LEVEL pk -6.0 · avg -9.0 dBFS · OK · audio 1.0 s / 1.0 s")
    }

    /// A format the mix cannot read still counts its frames, and says its
    /// level is unknown rather than silent.
    func testAnUnreadableFormatIsNotSilence() {
        var window = TelemetryWindow()
        window.add(frames: 512, seconds: 5, mono: nil, peak: 0)
        XCTAssertNil(window.rms)
        XCTAssertEqual(window.verdict, .unreadable)
        XCTAssertEqual(window.line(wallSeconds: 5), "LEVEL UNREADABLE (unsupported format) · audio 5.0 s / 5.0 s")
    }

    /// The verdict's thresholds: -0.1 dBFS clips, within 3 dB is hot.
    func testClippingAndHotLevelsAreNamed() {
        XCTAssertEqual(window(1.0).verdict, .clipped)
        XCTAssertEqual(window(0.99).verdict, .clipped)
        XCTAssertEqual(window(0.8).verdict, .hot)
        XCTAssertEqual(window(0.5).verdict, .ok)
        XCTAssertTrue(window(1.0).isProblem(wallSeconds: 0.01))
        XCTAssertFalse(window(0.8).isProblem(wallSeconds: 0.01))
    }

    /// An interval with no buffer at all still has a line, and says so: the
    /// watchdogs act on a stall, but the line shows it first.
    func testNoBuffersIsNoAudio() {
        let empty = TelemetryWindow()
        XCTAssertEqual(empty.verdict, .noAudio)
        XCTAssertEqual(empty.line(wallSeconds: 5), "LEVEL NO AUDIO (no buffers arrived) · audio 0.0 s / 5.0 s INPUT DROPPING")
    }

    /// Audio short of the time that passed, past half a second, is the input
    /// dropping out; a little short is buffers in flight.
    func testAShortIntervalIsTheInputDropping() {
        let short = window(0.5, buffers: 42, seconds: 0.1)   // 4.2 s
        XCTAssertNotNil(short.shortfall(wallSeconds: 5))
        XCTAssertTrue(short.line(wallSeconds: 5).contains("audio 4.2 s / 5.0 s INPUT DROPPING"))
        XCTAssertTrue(short.isProblem(wallSeconds: 5))

        let inFlight = window(0.5, buffers: 48, seconds: 0.1)  // 4.8 s
        XCTAssertNil(inFlight.shortfall(wallSeconds: 5))
        XCTAssertFalse(inFlight.isProblem(wallSeconds: 5))
    }

    /// Buffers the writer dropped or refused are counted, every one, not only
    /// the first, and the disk comes last.
    func testDropsFailuresAndTheDisk() {
        var w = window(0.5, buffers: 50, seconds: 0.1)
        w.noteDroppedBuffer()
        w.noteDroppedBuffer()
        w.noteFailedWrite()
        let disk = DiskReading(fileBytes: 412 * 1_048_576, freeBytes: 393 * 1_073_741_824,
                               reserveBytes: 0, bytesPerSecond: Double(393 * 1_073_741_824) / (30 * 3600))
        XCTAssertEqual(w.line(wallSeconds: 5, disk: disk),
                       "LEVEL pk -6.0 · avg -6.0 dBFS · OK · audio 5.0 s / 5.0 s · 2 buffers DROPPED (writer behind) · "
                       + "1 write FAILED · file 412.0 MB · free 393 GB (~30 h)")
        XCTAssertTrue(w.isProblem(wallSeconds: 5))
    }
}

/// The take's summary, and how sizes and times are written.
final class TakeTallyTests: XCTestCase {

    private func window(_ sample: Float, seconds: Double) -> TelemetryWindow {
        var window = TelemetryWindow()
        window.add(frames: 480, seconds: seconds, mono: [Float](repeating: sample, count: 480), peak: abs(sample))
        return window
    }

    /// A clean take reads as one, as an event.
    func testACleanTake() {
        var tally = TakeTally()
        tally.add(window(0.5, seconds: 5), wallSeconds: 5)
        tally.add(window(0.25, seconds: 5), wallSeconds: 5)
        let summary = tally.summary(seconds: 2530, fileBytes: 2 * 1_073_741_824, end: .saved, cause: "user",
                                    interruptions: 0, voice: VoiceDetector.Status(heard: true))
        XCTAssertEqual(summary.text, "TAKE // 00:42:10 · 2.00 GB · SAVED, stopped in the app · peak -6.0 dBFS · "
                       + "0 dropped · 0 short · 0 silent · 0 clipped · 0 interruptions · voice heard")
        XCTAssertEqual(summary.level, .event)
    }

    /// What went wrong is counted, in capitals, and the summary is a warning.
    func testATroubledTake() {
        var tally = TakeTally()
        tally.add(window(1.0, seconds: 5), wallSeconds: 5)
        tally.add(window(0, seconds: 5), wallSeconds: 5)
        tally.add(TelemetryWindow(), wallSeconds: 5)
        let summary = tally.summary(seconds: 15, fileBytes: nil, end: .recoverAtLaunch, cause: "dataStalled",
                                    interruptions: 1, voice: VoiceDetector.Status())
        XCTAssertEqual(summary.text, "TAKE // 00:00:15 · WRITER FAILED, the sidecar waits for the next launch, "
                       + "stopped: no audio arrived for 3 s · peak 0.0 dBFS · 0 dropped · 1 SHORT · 1 SILENT · "
                       + "1 CLIPPED · 1 interruption · NO VOICE HEARD")
        XCTAssertEqual(summary.level, .warn)
    }

    func testSizesAndTimes() {
        XCTAssertEqual(ServiceFormat.bytes(812 * 1024), "812 KB")
        XCTAssertEqual(ServiceFormat.bytes(412 * 1_048_576 + 314_573), "412.3 MB")
        XCTAssertEqual(ServiceFormat.bytes(Int64(1.93 * 1_073_741_824)), "1.93 GB")
        XCTAssertEqual(ServiceFormat.bytes(393 * 1_073_741_824), "393 GB")
        XCTAssertEqual(ServiceFormat.timeLeft(30), "<1 min")
        XCTAssertEqual(ServiceFormat.timeLeft(45 * 60), "~45 min")
        XCTAssertEqual(ServiceFormat.timeLeft(30 * 3600), "~30 h")
        XCTAssertEqual(ServiceFormat.timeLeft(6524 * 3600), "~271 days")
        XCTAssertEqual(ServiceFormat.transport("builtIn"), "built-in")
        XCTAssertEqual(ServiceFormat.transport("other:abcd"), "other:abcd")
    }

    /// The time left is to the disk watch's reserve, where the take stops,
    /// not to an empty disk.
    func testTimeLeftStopsAtTheReserve() {
        let disk = DiskReading(fileBytes: 0, freeBytes: 300, reserveBytes: 200, bytesPerSecond: 1)
        XCTAssertEqual(disk.secondsLeft, 100)
        XCTAssertNil(DiskReading(fileBytes: 0, freeBytes: 300).secondsLeft, "no rate, no estimate")
    }

    /// Text size steps stay in range.
    func testTextSizeIsClamped() {
        XCTAssertEqual(ServiceTextSize.clamped(40), ServiceTextSize.range.upperBound)
        XCTAssertEqual(ServiceTextSize.clamped(2), ServiceTextSize.range.lowerBound)
        XCTAssertEqual(ServiceTextSize.clamped(14.4), 14)
    }
}

/// Where the Service Monitor opens, next to the About window.
final class ServiceMonitorPlacementTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
    private let panel = NSSize(width: 580, height: 380)

    /// With room, centred under About.
    func testUnderTheAboutWindow() {
        let about = NSRect(x: 570, y: 450, width: 300, height: 285)
        XCTAssertEqual(ServiceMonitorPanel.topLeft(for: panel, near: about, within: screen),
                       NSPoint(x: 430, y: 438))
    }

    /// No room below: above it instead.
    func testAboveWhenAboutIsLow() {
        let about = NSRect(x: 570, y: 40, width: 300, height: 285)
        XCTAssertEqual(ServiceMonitorPanel.topLeft(for: panel, near: about, within: screen),
                       NSPoint(x: 430, y: 40 + 285 + 12 + 380))
    }

    /// No room either way, or near a side: kept inside the screen.
    func testInsideTheScreenWhateverTheRoom() {
        let about = NSRect(x: 1300, y: 300, width: 300, height: 285)
        let point = ServiceMonitorPanel.topLeft(for: panel, near: about, within: screen)
        XCTAssertEqual(point.x, 1440 - 580)
        XCTAssertGreaterThanOrEqual(point.y - panel.height, screen.minY)
        XCTAssertLessThanOrEqual(point.y, screen.maxY)
    }
}
