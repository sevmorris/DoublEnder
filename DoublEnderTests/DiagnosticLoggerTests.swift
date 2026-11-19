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

    /// A take adds two lines every 5 seconds, so an hour of one is 1,440 lines,
    /// and the handshake at its start used to have scrolled out by its end.
    /// Pinned, it stays.
    func testTheHandshakeSurvivesALongTake() {
        let logger = DiagnosticLogger()
        logger.log("HANDSHAKE // USB Mic · 48000 Hz", level: .event, pin: .input)
        logger.log("STATE IDLE -> ARMED // Ada.m4a [AAC]", level: .event, pin: .take)
        for i in 1...1_440 { logger.log("TLM // \(i)") }
        flushed(logger) { logger.lines.last?.text == "TLM // 1440" }

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

/// The `TLM` line's levels.
final class TelemetryWindowTests: XCTestCase {

    /// Zeros are SILENT, not the meter's -36 dB floor, which a quiet working
    /// input reads below.
    func testDigitalSilenceSaysSo() {
        var window = TelemetryWindow()
        window.add(frames: 480, mono: [Float](repeating: 0, count: 480), peak: 0)
        XCTAssertEqual(window.line, "TLM // 1 buf · 480 fr · SILENT (every sample zero)")

        var quiet = TelemetryWindow()
        quiet.add(frames: 480, mono: [Float](repeating: 0.001, count: 480), peak: 0.001)
        XCTAssertEqual(quiet.line, "TLM // 1 buf · 480 fr · peak -60.0 dBFS · rms -60.0 dBFS")
    }

    /// The RMS is the interval's: a loud buffer then a quiet one is not the
    /// quiet one's level.
    func testTheRMSCoversTheWholeInterval() {
        var window = TelemetryWindow()
        window.add(frames: 100, mono: [Float](repeating: 0.5, count: 100), peak: 0.5)
        window.add(frames: 100, mono: [Float](repeating: 0, count: 100), peak: 0)
        XCTAssertEqual(window.rms ?? 0, Float(0.5 / 2.0.squareRoot()), accuracy: 1e-6)
        XCTAssertEqual(window.peak, 0.5)
        XCTAssertEqual(window.frames, 200)
        XCTAssertTrue(window.line.hasSuffix("peak -6.0 dBFS · rms -9.0 dBFS"), window.line)
    }

    /// A format the mix cannot read still counts its frames, and says its
    /// level is unknown rather than silent.
    func testAnUnreadableFormatIsNotSilence() {
        var window = TelemetryWindow()
        window.add(frames: 512, mono: nil, peak: 0)
        XCTAssertNil(window.rms)
        XCTAssertEqual(window.line, "TLM // 1 buf · 512 fr · level unreadable (unsupported format)")
    }
}
