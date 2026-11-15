import Darwin
import Foundation

/// Says "this process is using it" about a file or folder, to another copy of
/// the app: an flock(2), held while this object lives. Two copies can run at
/// once (the installed one and one opened from the disk image, say), and each
/// looks at things the other may be in the middle of: the update staging
/// folders the launch sweep removes, and the takes waiting to upload.
///
/// The kernel drops the lock when the process ends, however it ends, so what a
/// crashed copy left is free again for whoever looks next. O_CLOEXEC keeps a
/// tool this process starts (the relaunch helper, hdiutil) from inheriting the
/// descriptor and holding the lock past the app. The same lock as a `.pcmrec`
/// sidecar's (`PCMSidecar`), which creates its file locked instead.
final class InUseLock {
    enum Attempt {
        case taken(InUseLock)
        /// Another process, or another lock in this one, holds it.
        case heldElsewhere
        /// It could not be opened (gone, say), so nobody can be using it.
        case unavailable
    }

    let url: URL
    private var fd: Int32
    private let guardLock = NSLock()

    private init(url: URL, fd: Int32) {
        self.url = url
        self.fd = fd
    }

    /// Takes the lock without waiting.
    static func take(_ url: URL) -> Attempt {
        let fd = Darwin.open(url.path, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return errno == EWOULDBLOCK ? .heldElsewhere : .unavailable }
        return .taken(InUseLock(url: url, fd: fd))
    }

    /// Whether someone holds the lock on `url` now. A file that cannot be
    /// opened is not in use.
    static func isHeld(_ url: URL) -> Bool {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        flock(fd, LOCK_UN)
        return false
    }

    /// Lets go now rather than when the object goes. From any thread.
    func release() {
        guardLock.lock()
        defer { guardLock.unlock() }
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    deinit { release() }
}

extension InUseLock.Attempt {
    /// The lock, when it was taken.
    var lock: InUseLock? {
        if case .taken(let lock) = self { return lock }
        return nil
    }
}
