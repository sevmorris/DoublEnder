import Foundation

/// Runs work on the main thread from the run loop itself rather than from the
/// main dispatch queue.
///
/// The difference decides whether a modal dialog freezes the app. A modal runs a
/// nested run loop. When that loop starts inside a block of the main dispatch
/// queue, and a main actor task is one, the nested loop does not service the
/// queue: every `DispatchQueue.main.async`, `receive(on: DispatchQueue.main)`,
/// `MainActor.run` and main actor continuation waits until the modal ends.
/// Timers and events still run. Started from the run loop (a timer, an event,
/// or this), the nested loop services the queue as usual.
///
/// 2.8.3cr opened the recorder from a `Task` once the launch update was done, so
/// crash recovery's dialog ran inside a main actor job: the conversion finished
/// on its own queue, its result never reached the dialog, and the spinner ran
/// for ever. Anything that may end in a modal starts from here.
@MainActor
enum MainRunLoop {
    /// Runs `block` on the next pass of the main run loop, or after `delay`, in
    /// every common mode, so it also runs under a modal that is already up.
    static func perform(after delay: TimeInterval = 0, _ block: @escaping @MainActor () -> Void) {
        if delay > 0 {
            let timer = Timer(timeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated { block() }
            }
            RunLoop.main.add(timer, forMode: .common)
        } else {
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { block() }
            }
        }
    }

    /// Suspends until the main run loop runs `body`, and returns its result. For
    /// main actor code about to run a modal: the modal then starts from the run
    /// loop, and the main queue stays live under it.
    static func run<T>(_ body: @escaping @MainActor () -> T) async -> T {
        await withCheckedContinuation { continuation in
            perform { continuation.resume(returning: body()) }
        }
    }
}
