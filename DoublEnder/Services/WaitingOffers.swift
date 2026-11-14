import Foundation

/// Offers that wait for their turn: each is made once the app is free to make
/// it, and never from inside the callback that raised it.
///
/// A USB input that appears is offered to the guest ("Switch to this input if
/// your microphone is connected through it"). It appears when it appears: at
/// launch, while a crashed take is being recovered or an unfinished upload is
/// being asked about; while the guest types their name; behind a confirmation.
/// Up to 2.8.3 the offer opened on top of whatever was up. 2.8.4 dropped it
/// instead, and nothing made it again, so that guest recorded on the built-in
/// microphone without ever being asked. Here it waits.
///
/// Two more things follow from waiting. Each offer opens from the run loop, not
/// from the main-queue block of the device callback that raised it, so the
/// main queue stays live under it (`MainRunLoop`). And an offer is looked at
/// again when its turn comes: a device unplugged meanwhile, or chosen by hand,
/// is not offered.
///
/// Main thread only.
final class WaitingOffers<ID: Hashable> {
    private var waiting: [ID] = []
    private var scheduled = false
    private var presenting = false

    private let canOpen: () -> Bool
    private let isWanted: (ID) -> Bool
    private let present: (ID) -> Void
    private let schedule: (@escaping () -> Void) -> Void

    /// - canOpen: whether an offer may open now. False keeps it waiting.
    /// - isWanted: whether this one is still worth making. False forgets it.
    /// - present: makes the offer, and returns when it has been answered.
    /// - schedule: runs a block on a later pass of the main run loop.
    init(canOpen: @escaping () -> Bool,
         isWanted: @escaping (ID) -> Bool,
         present: @escaping (ID) -> Void,
         schedule: @escaping (@escaping () -> Void) -> Void = WaitingOffers.onTheRunLoop) {
        self.canOpen = canOpen
        self.isWanted = isWanted
        self.present = present
        self.schedule = schedule
    }

    static func onTheRunLoop(_ block: @escaping () -> Void) {
        MainActor.assumeIsolated { MainRunLoop.perform { block() } }
    }

    var isEmpty: Bool { waiting.isEmpty }

    /// Adds an offer, and makes it as soon as it can be made.
    func add(_ id: ID) {
        assert(Thread.isMainThread)
        if !waiting.contains(id) { waiting.append(id) }
        retry()
    }

    /// What kept an offer waiting may be over: a dialog closed, a take ended.
    func retry() {
        assert(Thread.isMainThread)
        guard !waiting.isEmpty, !scheduled else { return }
        scheduled = true
        schedule { [weak self] in
            self?.scheduled = false
            self?.openNext()
        }
    }

    private func openNext() {
        // An offer that is up is answered before the next one opens.
        guard !presenting else { return }
        while let id = waiting.first {
            guard isWanted(id) else {
                waiting.removeFirst()
                continue
            }
            guard canOpen() else { return }
            waiting.removeFirst()
            presenting = true
            present(id)
            presenting = false
        }
    }
}
