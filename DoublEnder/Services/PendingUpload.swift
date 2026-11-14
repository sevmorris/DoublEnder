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
