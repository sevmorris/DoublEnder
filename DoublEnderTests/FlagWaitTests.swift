import Combine
import XCTest
@testable import DoublEnder

final class FlagWaitTests: XCTestCase {

    @MainActor
    func testItRunsOnceWhenTheFlagClears() {
        let flag = CurrentValueSubject<Bool, Never>(true)
        let done = expectation(description: "told")
        var results: [Bool] = []
        let wait = FlagWait(flag.eraseToAnyPublisher(), patience: 5) {
            results.append($0)
            done.fulfill()
        }
        flag.send(true)
        flag.send(false)
        flag.send(true)
        flag.send(false)
        self.wait(for: [done], timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(results, [true])
        _ = wait
    }

    @MainActor
    func testItGivesUpAfterItsPatience() {
        let flag = CurrentValueSubject<Bool, Never>(true)
        let done = expectation(description: "told")
        var results: [Bool] = []
        let started = Date()
        let wait = FlagWait(flag.eraseToAnyPublisher(), patience: 0.15) {
            results.append($0)
            done.fulfill()
        }
        self.wait(for: [done], timeout: 5)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.14)
        // Clearing afterwards tells nobody a second time.
        flag.send(false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(results, [false])
        _ = wait
    }

    @MainActor
    func testCancelledItSaysNothing() {
        let flag = CurrentValueSubject<Bool, Never>(true)
        var told = false
        let wait = FlagWait(flag.eraseToAnyPublisher(), patience: 0.1) { _ in told = true }
        wait.cancel()
        flag.send(false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertFalse(told)
    }
}
