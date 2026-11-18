import Foundation

/// Cloud: a take whose upload is under way or has failed, remembered across a
/// quit so the next launch can offer to finish it.
///
/// `sessionURI` and `crc32c` are there once Cloud Storage has opened a resumable
/// session for the file. With them, an upload carries on from what the server
/// has; without them (a quit before the session opened, or a record from before
/// resumable uploads) it starts again.
///
/// Only the Cloud build keeps one. It compiles into both so the public tests
/// hold it to its rules.
struct PendingUpload: Codable, Equatable {
    let path: String
    var sessionURI: String?
    var crc32c: String?

    init(path: String, sessionURI: String? = nil, crc32c: String? = nil) {
        self.path = path
        self.sessionURI = sessionURI
        self.crc32c = crc32c
    }

    /// The record as defaults hold it: JSON, or the bare path that a build
    /// before resumable uploads wrote.
    static func decode(_ raw: String?) -> PendingUpload? {
        guard let raw, !raw.isEmpty else { return nil }
        if let data = raw.data(using: .utf8),
           let record = try? JSONDecoder().decode(PendingUpload.self, from: data) {
            return record
        }
        return PendingUpload(path: raw)
    }

    var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// What to remember as an upload of `file` begins: the record already kept
    /// for that file, session and all, or a new one. A record for some other
    /// file is replaced, never carried over: its session holds that file's
    /// bytes and checksum.
    static func starting(_ file: URL, existing: PendingUpload?) -> PendingUpload {
        if let existing, existing.path == file.path { return existing }
        return PendingUpload(path: file.path)
    }

    /// The session to carry on with, if this record is for `file` and has one.
    func session(for file: URL) -> (uri: URL, crc32c: String)? {
        guard path == file.path,
              let sessionURI, let uri = URL(string: sessionURI),
              let crc32c else { return nil }
        return (uri, crc32c)
    }

    var withoutSession: PendingUpload {
        PendingUpload(path: path)
    }

    /// True for the status Cloud Storage gives a session it no longer has: 410
    /// within a week of opening it, 404 after. Its documentation says such an
    /// upload has to be started again, with a new session. Until this was
    /// read, an upload left unfinished for more than a week failed at every
    /// retry and at every launch, and the faceplate shows nothing but RETRY
    /// UPLOAD while one has failed.
    static func sessionIsGone(status: Int?) -> Bool {
        status == 404 || status == 410
    }
}

/// Cloud: every take still to be uploaded, oldest first.
///
/// One record used to do. Since a guest can choose Later on a failed upload and
/// record again, and Skip at launch keeps a take for the next launch, more than
/// one can wait. Uploads still run one at a time.
///
/// The list is JSON under `listKey`. Its first record is also written under
/// `legacyKey`, the single record's own key, which a version from before the
/// list reads: a rollback to one keeps at least that take. A list that is
/// empty removes both.
struct PendingUploads: Equatable {
    static let listKey = "pendingUploads"
    static let legacyKey = "pendingUploadURL"

    private(set) var items: [PendingUpload]

    init(_ items: [PendingUpload] = []) {
        self.items = items
    }

    static func load(from defaults: UserDefaults) -> PendingUploads {
        if let data = defaults.string(forKey: listKey)?.data(using: .utf8),
           let items = try? JSONDecoder().decode([PendingUpload].self, from: data) {
            return PendingUploads(items)
        }
        // A single record from before the list.
        return PendingUploads(PendingUpload.decode(defaults.string(forKey: legacyKey)).map { [$0] } ?? [])
    }

    func save(to defaults: UserDefaults) {
        guard let head = items.first,
              let data = try? JSONEncoder().encode(items),
              let list = String(data: data, encoding: .utf8) else {
            defaults.removeObject(forKey: Self.listKey)
            defaults.removeObject(forKey: Self.legacyKey)
            return
        }
        defaults.set(list, forKey: Self.listKey)
        if let legacy = head.encoded { defaults.set(legacy, forKey: Self.legacyKey) }
    }

    func record(for file: URL) -> PendingUpload? {
        items.first { $0.path == file.path }
    }

    var paths: [String] { items.map(\.path) }

    /// Adds `file` at the end, unless it is waiting already: then its record,
    /// session and all, stays where it is.
    mutating func add(_ file: URL) {
        guard record(for: file) == nil else { return }
        items.append(PendingUpload(path: file.path))
    }

    /// Replaces the record for the same file, if there is one.
    mutating func update(_ record: PendingUpload) {
        guard let index = items.firstIndex(where: { $0.path == record.path }) else { return }
        items[index] = record
    }

    mutating func remove(_ file: URL) {
        items.removeAll { $0.path == file.path }
    }

    /// Drops the takes whose files are gone (deleted, moved), and returns the
    /// rest.
    @discardableResult
    mutating func dropMissing(exists: (String) -> Bool) -> [PendingUpload] {
        items.removeAll { !exists($0.path) }
        return items
    }
}

/// `PendingUploads` in defaults, one change at a time. The upload runs off the
/// main thread and writes its session as it goes; a take is added on the main
/// thread meanwhile. Each change reads, changes and writes under one lock, so
/// neither is lost.
final class PendingUploadStore: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var current: PendingUploads {
        lock.lock(); defer { lock.unlock() }
        return PendingUploads.load(from: defaults)
    }

    @discardableResult
    func change<T>(_ body: (inout PendingUploads) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        var uploads = PendingUploads.load(from: defaults)
        let result = body(&uploads)
        uploads.save(to: defaults)
        return result
    }
}

/// What one upload does between its attempts (`RecorderViewModel.performUpload`).
///
/// A failed attempt is retried after 2, 4 and 8 s, and the fourth failure ends
/// the upload ("Upload failed"). A failure that says the Mac has no connection,
/// while `CloudConnectivity` agrees that it has none, spends no retry: the
/// upload waits for the connection to come back, up to `networkWaitLimit` in
/// all, and then tries again. A closed lid or a lost Wi-Fi drops the
/// connection mid-upload, and after a wake Wi-Fi can take longer to rejoin than
/// 2 + 4 + 8 s: until 2026-11-18 every retry could fail before it had, and the
/// guest was told the upload had failed, though the automatic upload took it up
/// later. Past the limit the retries are spent as before, so an upload never
/// waits more than `networkWaitLimit` longer than it used to.
struct UploadRetry {
    /// The waits before retries 1, 2 and 3.
    static let backoffSeconds: [UInt64] = [2, 4, 8]
    /// The longest one upload waits, in all, for the connection to come back.
    static let networkWaitLimit: UInt64 = 120
    /// How often a wait for the connection looks again.
    static let networkPollSeconds: UInt64 = 1

    enum Wait: Equatable {
        /// No more attempts: the upload has failed.
        case giveUp
        /// Retry after this many seconds; the retry is spent.
        case backoff(UInt64)
        /// Wait for the connection (`waitForNetwork`), then retry; nothing is spent.
        case network
    }

    private(set) var retriesSpent = 0
    private(set) var networkWaited: UInt64 = 0

    /// What follows a failed attempt. `networkReady` is the connection as
    /// `CloudConnectivity` sees it now.
    mutating func next(after error: Error, nonRetryable: Bool, networkReady: Bool) -> Wait {
        if nonRetryable { return .giveUp }
        if !networkReady, Self.isConnectivity(error), networkWaited < Self.networkWaitLimit {
            return .network
        }
        guard retriesSpent < Self.backoffSeconds.count else { return .giveUp }
        let delay = Self.backoffSeconds[retriesSpent]
        retriesSpent += 1
        return .backoff(delay)
    }

    /// Waits until `isReady`, or until this upload has waited
    /// `networkWaitLimit` in all. `sleep` throws when the upload is called off.
    mutating func waitForNetwork(isReady: () -> Bool, sleep: (UInt64) async throws -> Void) async throws {
        while !isReady(), networkWaited < Self.networkWaitLimit {
            try await sleep(Self.networkPollSeconds)
            networkWaited += Self.networkPollSeconds
        }
    }

    /// An error that says the Mac has no working connection now, as opposed
    /// to one from Cloud Storage.
    static func isConnectivity(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
             .callIsActive:
            return true
        default:
            return false
        }
    }
}

/// The connection as `CloudConnectivity` last said, for code off the main
/// queue: an upload must not wait for that queue, which a modal dialog holds.
final class NetworkReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready
    }

    func set(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        ready = value
    }
}

/// Cloud: when a take that is waiting uploads by itself.
///
/// After a failed upload the guest can choose Later and go on recording; the
/// take uploads by itself when the connection comes back, or after the next
/// upload that succeeds. Never over a take, a dialog or another upload, and
/// only so often: a failure that will not go away (a clock far enough off that
/// Cloud Storage refuses the signature) must not upload again at every flicker
/// of the Wi-Fi.
enum AutomaticUpload {
    /// Automatic attempts at one take in one run of the app.
    static let maximumAttempts = 3
    /// Between two automatic starts.
    static let minimumGap: TimeInterval = 60

    struct Situation: Equatable {
        var cloudOn: Bool
        /// Ready to record, or showing a failed upload's card: no take, no
        /// upload, no take about to start.
        var idle: Bool
        var dialogUp: Bool
        var networkReady: Bool
        var lastStart: Date?
        var now: Date
    }

    static func mayStart(_ situation: Situation) -> Bool {
        guard situation.cloudOn, situation.idle, !situation.dialogUp, situation.networkReady else { return false }
        guard let last = situation.lastStart else { return true }
        return situation.now.timeIntervalSince(last) >= minimumGap
    }

    /// The take to upload next: the oldest one waiting that the guest has not
    /// put off until the next launch (`skipped`), whose file is there, that
    /// has attempts left, and that no other copy of the app is uploading.
    static func next(in uploads: PendingUploads, skipped: Set<String>, attempts: [String: Int],
                     exists: (String) -> Bool,
                     uploadingElsewhere: (String) -> Bool = AutomaticUpload.isUploadingElsewhere) -> PendingUpload? {
        uploads.items.first { record in
            !skipped.contains(record.path)
                && (attempts[record.path] ?? 0) < maximumAttempts
                && exists(record.path)
                && !uploadingElsewhere(record.path)
        }
    }

    /// Whether another copy of the app is uploading the take at `path`: each
    /// copy locks a take for as long as it uploads it (`InUseLock`). Two copies
    /// share the list of takes waiting (the installed one and one opened from
    /// the disk image, say). Until 2026-11-15 the second offered a take the
    /// first was uploading, and with no session stored yet each uploaded it
    /// under a name of its own, so the producer got it twice.
    static func isUploadingElsewhere(_ path: String) -> Bool {
        InUseLock.isHeld(URL(fileURLWithPath: path))
    }
}
