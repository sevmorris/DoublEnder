import AppKit

/// A vetted copy of a new version, staged beside the app it will replace.
struct StagedUpdate: Equatable {
    /// The version the check offered, for the words on screen.
    var version: String
    /// The copy, in a folder of its own on the installed app's volume.
    var staged: URL
    /// Where the running app was when staging began.
    var installed: URL
}

/// A file as the file system knows it, whatever path leads to it now.
struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64

    init?(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        device = UInt64(truncatingIfNeeded: info.st_dev)
        inode = UInt64(truncatingIfNeeded: info.st_ino)
    }
}

/// The last step of an update: replace the installed app and quit.
///
/// It is one synchronous function on purpose. From its first check to the quit
/// there is no `await`, and the compiler holds it to that, so no take can
/// start, no upload can begin and no dialog can open in between: nothing else
/// gets the main thread. It asks `isBlocked` itself, first, so the property
/// does not depend on what its caller did a moment before.
///
/// The order is the design:
///   1. Nothing in flight, or stop.
///   2. From here nothing new may start (`beginCommitting`).
///   3. The staged copy is still the vetted one. It may have waited in a
///      temporary folder through a long take, where any process of this user
///      can write, with none of the protection the installed app has.
///   4. The app at the target path is still this one. A copy the user moved
///      or replaced meanwhile must not be swapped out and thrown away.
///   5. The previous version is put on probation (`UpdateRollback`).
///   6. The relaunch helper is running. If it cannot be started the update
///      stops here, with the installed app untouched, rather than after the
///      swap, where the choice was quitting for good or running old code over
///      a new bundle.
///   7. The swap, in one step. If it fails, 5 and 6 are undone.
///   8. Quit.
struct UpdateCommit {

    enum Refusal: LocalizedError, Equatable {
        /// Something started between the caller's check and this one.
        case busy
        case stagedCopyChanged
        case appMoved
        case cannotRelaunch(String)

        var errorDescription: String? {
            switch self {
            case .busy:
                return "The app became busy before the update could be installed."
            case .stagedCopyChanged:
                return "The downloaded copy changed after it was checked, so it was not installed."
            case .appMoved:
                return "The app was moved or replaced while the update was waiting."
            case .cannotRelaunch(let reason):
                return "The app couldn't arrange to reopen itself (\(reason)), so the update was not installed."
            }
        }
    }

    /// Something that can still be called off: the relaunch helper.
    struct Undo {
        var cancel: () -> Void
    }

    var isBlocked: () -> Bool
    var beginCommitting: () -> Void
    var endCommitting: () -> Void
    var stagedCopyIsStillVetted: (StagedUpdate) -> Bool
    var targetIsTheRunningApp: (URL) -> Bool
    var armProbation: (StagedUpdate) -> Void
    var disarmProbation: () -> Void
    var prepareRelaunch: (URL) throws -> Undo
    var swap: (_ staged: URL, _ installed: URL) throws -> Void
    var terminate: () -> Void

    func callAsFunction(_ update: StagedUpdate) throws {
        guard !isBlocked() else { throw Refusal.busy }
        beginCommitting()
        do {
            guard stagedCopyIsStillVetted(update) else { throw Refusal.stagedCopyChanged }
            guard targetIsTheRunningApp(update.installed) else { throw Refusal.appMoved }
            armProbation(update)
            do {
                let relaunch: Undo
                do {
                    relaunch = try prepareRelaunch(update.installed)
                } catch {
                    throw Refusal.cannotRelaunch(error.localizedDescription)
                }
                do {
                    try swap(update.staged, update.installed)
                } catch {
                    relaunch.cancel()
                    throw error
                }
            } catch {
                disarmProbation()
                throw error
            }
        } catch {
            // The installed app is as it was, and the app carries on.
            endCommitting()
            throw error
        }
        terminate()
    }
}

extension UpdateCommit {
    /// The real thing. `runningExecutable` is the running app's executable as
    /// the file system knew it at launch, before anything could replace it.
    @MainActor
    static func live(store: UpdateStateStore, activity: AppActivity, expected: SelfUpdater.Expected,
                     runningExecutable: FileIdentity? = AppLauncher.runningExecutable,
                     executableName: String? = AppLauncher.executableName) -> UpdateCommit {
        UpdateCommit(
            isBlocked: { activity.blocksRelaunch },
            beginCommitting: { activity.beginCommittingUpdate() },
            endCommitting: { activity.endCommittingUpdate() },
            // The same checks as at staging, strict signature validation
            // included, on the copy as it is now.
            stagedCopyIsStillVetted: { (try? SelfUpdater.vet($0.staged, against: expected)) != nil },
            targetIsTheRunningApp: { installed in
                guard let runningExecutable, let executableName else { return false }
                let executable = installed.appendingPathComponent("Contents/MacOS").appendingPathComponent(executableName)
                return FileIdentity(executable) == runningExecutable
            },
            armProbation: { update in
                UpdateRollback.arm(from: expected.installedVersion,
                                   to: bundleVersion(at: update.staged) ?? update.version,
                                   previous: update.staged, installed: update.installed, store: store)
            },
            disarmProbation: { UpdateRollback.disarm(store: store) },
            prepareRelaunch: { installed in
                let helper = try UpdateRelauncher.prepare(toOpen: installed, marker: store.markerURL)
                return Undo { helper.terminate() }
            },
            swap: { try SelfUpdater.swap(staged: $0, into: $1) },
            terminate: {
                // isBlocked was the first step, and nothing has run since, so a
                // quit has nothing to ask. AppDelegate's intercept reads the
                // same AppActivity, and a question here could never be answered.
                assert(activity.quitQuestion == nil, "an update's quit must never meet a question")
                NSApp.terminate(nil)
            })
    }
}
