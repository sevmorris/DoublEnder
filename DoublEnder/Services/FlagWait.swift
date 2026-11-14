import Combine
import Foundation

/// Waits for a published flag to clear, for no longer than `patience`, and then
/// runs `then` once, on the main thread, saying whether it cleared.
///
/// The recorder uses it for a take that is asked for while the capture session
/// is being rebuilt on another input: the rebuild runs off the main thread, and
/// starting before it is done fails with "Audio engine is not running".
final class FlagWait {
    private var subscription: AnyCancellable?
    private var timer: Timer?
    private var then: ((Bool) -> Void)?

    init(_ flag: AnyPublisher<Bool, Never>, patience: TimeInterval, then: @escaping (_ cleared: Bool) -> Void) {
        assert(Thread.isMainThread)
        self.then = then
        let timer = Timer(timeInterval: patience, repeats: false) { [weak self] _ in self?.finish(cleared: false) }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Through the main queue: a @Published flag sends its new value before
        // it holds it, and whoever is told must find it already set.
        subscription = flag
            .filter { !$0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.finish(cleared: true) }
    }

    func cancel() {
        then = nil
        subscription = nil
        timer?.invalidate()
        timer = nil
    }

    private func finish(cleared: Bool) {
        guard let then else { return }
        cancel()
        then(cleared)
    }
}
