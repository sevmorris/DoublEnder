import XCTest
@testable import DoublEnder

/// Whether the main dispatch queue is serviced under a modal depends on where
/// the modal was started from. These pin both halves: the fault (a main actor
/// task or a main queue block starves the queue) and the cure (`MainRunLoop`).
final class MainRunLoopTests: XCTestCase {

    /// Runs a nested run loop in the mode a modal dialog uses, and says whether
    /// a block sent to the main queue from another thread ran during it.
    @MainActor
    static func mainQueueIsServicedUnderAModalLoop(for seconds: TimeInterval = 0.4) -> Bool {
        final class Flag: @unchecked Sendable { var raised = false }
        let flag = Flag()
        DispatchQueue.global().async {
            DispatchQueue.main.async { flag.raised = true }
        }
        let end = Date().addingTimeInterval(seconds)
        while !flag.raised && Date() < end {
            _ = RunLoop.current.run(mode: .modalPanel, before: end)
        }
        return flag.raised
    }

    @MainActor
    func testAModalStartedFromAMainActorTaskStarvesTheMainQueue() {
        let done = expectation(description: "task ran")
        var serviced = true
        Task { @MainActor in
            serviced = Self.mainQueueIsServicedUnderAModalLoop()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertFalse(serviced, "the mechanism this helper exists for no longer holds; revisit MainRunLoop")
    }

    @MainActor
    func testAModalStartedFromAMainQueueBlockStarvesTheMainQueue() {
        let done = expectation(description: "block ran")
        var serviced = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                serviced = Self.mainQueueIsServicedUnderAModalLoop()
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
        XCTAssertFalse(serviced)
    }

    @MainActor
    func testPerformKeepsTheMainQueueLiveUnderAModal() {
        let done = expectation(description: "block ran")
        var serviced = false
        MainRunLoop.perform {
            serviced = Self.mainQueueIsServicedUnderAModalLoop()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(serviced)
    }

    @MainActor
    func testPerformAfterADelayKeepsTheMainQueueLiveUnderAModal() {
        let done = expectation(description: "block ran")
        var serviced = false
        let started = Date()
        var waited: TimeInterval = 0
        MainRunLoop.perform(after: 0.1) {
            waited = Date().timeIntervalSince(started)
            serviced = Self.mainQueueIsServicedUnderAModalLoop()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(serviced)
        XCTAssertGreaterThanOrEqual(waited, 0.09)
    }

    /// What the audio engine uses to tell the recorder a take is closed or the
    /// input has gone: the recorder answers with a dialog. From a background
    /// thread, as `finishWriting` calls back.
    @MainActor
    func testDeliverFromABackgroundThreadKeepsTheMainQueueLiveUnderAModal() {
        let done = expectation(description: "block ran")
        var serviced = false
        DispatchQueue.global().async {
            MainRunLoop.deliver {
                serviced = Self.mainQueueIsServicedUnderAModalLoop()
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(serviced)
    }

    /// And from inside a block of the main queue, where the device listener
    /// runs: a modal started right there would starve the queue (above).
    @MainActor
    func testDeliverFromAMainQueueBlockKeepsTheMainQueueLiveUnderAModal() {
        let done = expectation(description: "block ran")
        var serviced = false
        DispatchQueue.main.async {
            MainRunLoop.deliver {
                serviced = Self.mainQueueIsServicedUnderAModalLoop()
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(serviced)
    }

    /// It keeps `DispatchQueue.main.async`'s place in line: what was sent to
    /// the main queue before it runs before it.
    @MainActor
    func testDeliverComesAfterWhatIsAlreadyOnTheMainQueue() {
        let done = expectation(description: "block ran")
        var order: [String] = []
        DispatchQueue.main.async { order.append("queued first") }
        MainRunLoop.deliver {
            order.append("delivered")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(order, ["queued first", "delivered"])
    }

    /// The engine's own use of it. A stop with nothing to stop still calls
    /// back, and that call must leave the queue live: the recorder's answer to
    /// a finished take is a dialog. No capture session is involved.
    @MainActor
    func testTheEnginesStopCompletionLeavesTheMainQueueLive() {
        let done = expectation(description: "completion ran")
        var serviced = false
        let engine = AudioEngine()
        engine.stopRecording { _ in
            MainActor.assumeIsolated {
                serviced = Self.mainQueueIsServicedUnderAModalLoop()
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(serviced, "a dialog opened from a stop's completion would hold the main queue")
    }

    /// The form async code uses before it runs a modal.
    @MainActor
    func testRunFromAMainActorTaskKeepsTheMainQueueLiveUnderAModal() {
        let done = expectation(description: "task ran")
        var serviced = false
        Task { @MainActor in
            serviced = await MainRunLoop.run { Self.mainQueueIsServicedUnderAModalLoop() }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(serviced)
    }
}
