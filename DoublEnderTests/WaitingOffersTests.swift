import Combine
import XCTest
@testable import DoublEnder

/// A USB input that appears is offered once the app is free to offer it. 2.8.4
/// dropped the offer whenever another dialog was up, and never made it again.
final class WaitingOffersTests: XCTestCase {

    /// The run loop, by hand: blocks run when the test says so.
    private final class Scheduler {
        private var blocks: [() -> Void] = []
        var pending: Int { blocks.count }

        func schedule(_ block: @escaping () -> Void) {
            blocks.append(block)
        }

        func runAll() {
            while !blocks.isEmpty {
                blocks.removeFirst()()
            }
        }
    }

    private final class World {
        var canOpen = true
        var unwanted: Set<String> = []
        var presented: [String] = []
        var onPresent: ((String) -> Void)?
        let scheduler = Scheduler()

        lazy var offers = WaitingOffers<String>(
            canOpen: { [unowned self] in canOpen },
            isWanted: { [unowned self] in !unwanted.contains($0) },
            present: { [unowned self] id in
                presented.append(id)
                onPresent?(id)
            },
            schedule: { [unowned self] in scheduler.schedule($0) })
    }

    /// The device callback that raises an offer runs in a block of the main
    /// queue, and a dialog opened from there holds the queue (`MainRunLoop`).
    func testAnOfferNeverOpensInsideTheCallThatRaisedIt() {
        let world = World()
        world.offers.add("usb")
        XCTAssertTrue(world.presented.isEmpty)
        world.scheduler.runAll()
        XCTAssertEqual(world.presented, ["usb"])
        XCTAssertTrue(world.offers.isEmpty)
    }

    /// The regression: a dialog is up when the device is found. The offer waits
    /// and is made when the dialog has closed.
    func testAnOfferWaitsWhileItCannotOpenAndOpensWhenItCan() {
        let world = World()
        world.canOpen = false
        world.offers.add("usb")
        world.scheduler.runAll()
        XCTAssertTrue(world.presented.isEmpty)
        XCTAssertFalse(world.offers.isEmpty, "the offer was dropped")

        // Trying again while nothing has changed opens nothing.
        world.offers.retry()
        world.scheduler.runAll()
        XCTAssertTrue(world.presented.isEmpty)

        world.canOpen = true
        world.offers.retry()
        world.scheduler.runAll()
        XCTAssertEqual(world.presented, ["usb"])
    }

    /// Unplugged again, chosen by hand, or turned down, while it waited.
    func testAnOfferNoLongerWantedIsForgotten() {
        let world = World()
        world.canOpen = false
        world.offers.add("usb")
        world.scheduler.runAll()

        world.unwanted = ["usb"]
        world.canOpen = true
        world.offers.retry()
        world.scheduler.runAll()
        XCTAssertTrue(world.presented.isEmpty)
        XCTAssertTrue(world.offers.isEmpty)
    }

    func testOffersOpenOneAfterAnotherInTheOrderTheyCame() {
        let world = World()
        world.offers.add("first")
        world.offers.add("second")
        world.offers.add("first")
        XCTAssertEqual(world.scheduler.pending, 1, "one pass of the run loop serves them all")
        world.scheduler.runAll()
        XCTAssertEqual(world.presented, ["first", "second"])
    }

    /// A second device is plugged in while the first offer is on screen.
    func testAnOfferRaisedWhileAnotherIsUpFollowsIt() {
        let world = World()
        var depth = 0
        var deepest = 0
        world.onPresent = { id in
            depth += 1
            deepest = max(deepest, depth)
            if id == "first" {
                world.offers.add("second")
                // The run loop turns under the first offer's dialog.
                world.scheduler.runAll()
            }
            depth -= 1
        }
        world.offers.add("first")
        world.scheduler.runAll()
        XCTAssertEqual(world.presented, ["first", "second"])
        XCTAssertEqual(deepest, 1, "the second offer opened on top of the first")
    }

    /// An offer that cannot open keeps its place, and the ones behind it wait
    /// with it: what blocks one (a take, a dialog) blocks them all.
    func testNothingJumpsAnOfferThatIsWaiting() {
        let world = World()
        world.canOpen = false
        world.offers.add("first")
        world.offers.add("second")
        world.scheduler.runAll()
        world.canOpen = true
        world.offers.retry()
        world.scheduler.runAll()
        XCTAssertEqual(world.presented, ["first", "second"])
    }

    // MARK: - With the gate

    /// End to end with `ModalGate`, as the recorder wires it: an offer raised
    /// under a dialog opens by itself once the dialog has closed, from the run
    /// loop, with the main queue live under it.
    @MainActor
    func testAnOfferRaisedUnderADialogOpensWhenTheDialogCloses() {
        let activity = AppActivity()
        var openedUnderTheDialog = false
        var servicedUnderTheOffer: Bool?
        var dialogIsUp = false
        let opened = expectation(description: "the offer opened")

        let offers = WaitingOffers<String>(
            canOpen: { ModalGate.canOpenOffer(activity: activity) },
            isWanted: { _ in true },
            present: { _ in
                openedUnderTheDialog = dialogIsUp
                ModalGate.run(.prompt, activity: activity) {
                    servicedUnderTheOffer = MainRunLoopTests.mainQueueIsServicedUnderAModalLoop()
                }
                opened.fulfill()
            })
        let closed = NotificationCenter.default.publisher(for: ModalGate.didChange)
            .sink { _ in offers.retry() }
        defer { closed.cancel() }

        // A dialog from a block of the main queue, as the device callback's
        // would be, with the device turning up while it is on screen.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                ModalGate.run(activity: activity) {
                    dialogIsUp = true
                    offers.add("usb")
                    let end = Date().addingTimeInterval(0.3)
                    while Date() < end {
                        _ = RunLoop.current.run(mode: .modalPanel, before: end)
                    }
                    dialogIsUp = false
                }
            }
        }
        wait(for: [opened], timeout: 5)
        XCTAssertFalse(openedUnderTheDialog)
        XCTAssertEqual(servicedUnderTheOffer, true)
        XCTAssertTrue(offers.isEmpty)
    }
}
