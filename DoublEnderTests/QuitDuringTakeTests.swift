import AppKit
import XCTest
@testable import DoublEnder

/// The answer to "Recording in progress", when the take has ended meanwhile.
final class QuitDuringTakeTests: XCTestCase {

    func testWithTheTakeStillRunningTheAnswerIsCarriedOut() {
        XCTAssertEqual(QuitDuringTake.action(for: .alertFirstButtonReturn, takeInProgress: true), .stopThenQuit)
        XCTAssertEqual(QuitDuringTake.action(for: .alertSecondButtonReturn, takeInProgress: true), .discardThenQuit)
        XCTAssertEqual(QuitDuringTake.action(for: .alertThirdButtonReturn, takeInProgress: true), .stay)
    }

    /// The producer stopped it from the dashboard, or the microphone was
    /// unplugged, while the question was up. There is nothing left to stop,
    /// and nothing that should be deleted: the quit is decided afresh, and an
    /// upload under way gets its own question.
    func testWithTheTakeOverNeitherAnswerTouchesIt() {
        XCTAssertEqual(QuitDuringTake.action(for: .alertFirstButtonReturn, takeInProgress: false), .askAgain)
        XCTAssertEqual(QuitDuringTake.action(for: .alertSecondButtonReturn, takeInProgress: false), .askAgain)
    }

    func testCancelStaysWhateverHappenedToTheTake() {
        XCTAssertEqual(QuitDuringTake.action(for: .alertThirdButtonReturn, takeInProgress: false), .stay)
    }

    /// The question could not open: an update is replacing the app.
    func testNoAnswerStays() {
        XCTAssertEqual(QuitDuringTake.action(for: nil, takeInProgress: true), .stay)
        XCTAssertEqual(QuitDuringTake.action(for: nil, takeInProgress: false), .stay)
    }
}
