import XCTest
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
}
