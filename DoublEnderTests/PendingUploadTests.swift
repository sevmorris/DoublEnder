import XCTest
@testable import DoublEnder

/// Cloud's record of a take still to be uploaded. The type compiles into both
/// builds so these run in public CI; only Cloud keeps one.
final class PendingUploadTests: XCTestCase {

    private let take = URL(fileURLWithPath: "/Users/guest/Desktop/Ada.m4a")
    private let other = URL(fileURLWithPath: "/Users/guest/Desktop/Ada_2.m4a")

    func testItSurvivesDefaults() throws {
        let record = PendingUpload(path: take.path, sessionURI: "https://storage.test/session", crc32c: "AAAAAA==")
        XCTAssertEqual(PendingUpload.decode(try XCTUnwrap(record.encoded)), record)
        XCTAssertNil(PendingUpload.decode(nil))
        XCTAssertNil(PendingUpload.decode(""))
    }

    /// A build before resumable uploads stored the path alone.
    func testABarePathIsARecordWithNoSession() {
        XCTAssertEqual(PendingUpload.decode(take.path), PendingUpload(path: take.path))
    }

    func testStartingAnUploadKeepsTheSessionOfTheSameFile() {
        let existing = PendingUpload(path: take.path, sessionURI: "https://storage.test/session", crc32c: "AAAAAA==")
        XCTAssertEqual(PendingUpload.starting(take, existing: existing), existing)
        XCTAssertEqual(PendingUpload.starting(take, existing: nil), PendingUpload(path: take.path))
    }

    /// Another file's session holds that file's bytes and checksum: sending
    /// this file to it can only end in a checksum refusal, at every retry.
    func testAnotherFilesSessionIsNeverCarriedOver() {
        let existing = PendingUpload(path: take.path, sessionURI: "https://storage.test/session", crc32c: "AAAAAA==")
        XCTAssertEqual(PendingUpload.starting(other, existing: existing), PendingUpload(path: other.path))
        XCTAssertNil(existing.session(for: other))
    }

    func testTheSessionNeedsBothItsAddressAndItsChecksum() throws {
        let whole = PendingUpload(path: take.path, sessionURI: "https://storage.test/session", crc32c: "AAAAAA==")
        let session = try XCTUnwrap(whole.session(for: take))
        XCTAssertEqual(session.uri, URL(string: "https://storage.test/session"))
        XCTAssertEqual(session.crc32c, "AAAAAA==")

        XCTAssertNil(PendingUpload(path: take.path, sessionURI: "https://storage.test/session").session(for: take))
        XCTAssertNil(PendingUpload(path: take.path, crc32c: "AAAAAA==").session(for: take))
        XCTAssertNil(PendingUpload(path: take.path).session(for: take))
        XCTAssertNil(whole.withoutSession.session(for: take))
        XCTAssertEqual(whole.withoutSession.path, take.path)
    }

    /// Cloud Storage keeps a session for a week. After that it answers 404,
    /// and 410 for one it dropped sooner; either way the upload has to start
    /// again. Anything else is a failure of this attempt, and the session is
    /// what makes the next one resume.
    func testOnlyAMissingSessionIsGivenUp() {
        XCTAssertTrue(PendingUpload.sessionIsGone(status: 404))
        XCTAssertTrue(PendingUpload.sessionIsGone(status: 410))
        for status in [nil, 308, 400, 403, 408, 429, 500, 503] as [Int?] {
            XCTAssertFalse(PendingUpload.sessionIsGone(status: status), "\(String(describing: status))")
        }
    }
}
