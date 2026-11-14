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

/// Every take still to be uploaded, kept across quits. LATER and SKIP mean more
/// than one can wait.
final class PendingUploadsTests: XCTestCase {

    private var folder: URL!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingUploadsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = folder.appendingPathComponent("defaults").path
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suite)
        defaults = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func take(_ name: String) -> URL { folder.appendingPathComponent(name) }

    func testTakesWaitInTheOrderTheyCame() {
        var uploads = PendingUploads()
        uploads.add(take("A.m4a"))
        uploads.add(take("B.m4a"))
        uploads.add(take("A.m4a"))
        XCTAssertEqual(uploads.paths, [take("A.m4a").path, take("B.m4a").path])
    }

    /// A take already waiting keeps its session: the upload resumes.
    func testAddingAWaitingTakeAgainKeepsItsSession() {
        var uploads = PendingUploads()
        uploads.add(take("A.m4a"))
        uploads.update(PendingUpload(path: take("A.m4a").path, sessionURI: "https://storage.test/s", crc32c: "AAAAAA=="))
        uploads.add(take("A.m4a"))
        XCTAssertNotNil(uploads.record(for: take("A.m4a"))?.session(for: take("A.m4a")))
    }

    /// Success removes that take only: others wait behind it.
    func testRemovingATakeLeavesTheOthers() {
        var uploads = PendingUploads()
        uploads.add(take("A.m4a"))
        uploads.add(take("B.m4a"))
        uploads.remove(take("A.m4a"))
        XCTAssertEqual(uploads.paths, [take("B.m4a").path])
    }

    func testTakesWhoseFilesAreGoneAreForgotten() throws {
        try Data().write(to: take("Kept.m4a"))
        var uploads = PendingUploads()
        uploads.add(take("Deleted.m4a"))
        uploads.add(take("Kept.m4a"))
        let left = uploads.dropMissing { FileManager.default.fileExists(atPath: $0) }
        XCTAssertEqual(left.map(\.path), [take("Kept.m4a").path])
    }

    func testTheListSurvivesAQuit() {
        var uploads = PendingUploads()
        uploads.add(take("A.m4a"))
        uploads.add(take("B.m4a"))
        uploads.save(to: defaults)
        XCTAssertEqual(PendingUploads.load(from: defaults), uploads)
    }

    /// 2.8.4 kept one record under its own key: it becomes the list.
    func testASingleRecordFromBeforeBecomesTheList() throws {
        let old = PendingUpload(path: take("Old.m4a").path, sessionURI: "https://storage.test/s", crc32c: "AAAAAA==")
        defaults.set(try XCTUnwrap(old.encoded), forKey: PendingUploads.legacyKey)
        XCTAssertEqual(PendingUploads.load(from: defaults).items, [old])
        // And a bare path, from before resumable uploads.
        defaults.set(take("Older.m4a").path, forKey: PendingUploads.legacyKey)
        XCTAssertEqual(PendingUploads.load(from: defaults).paths, [take("Older.m4a").path])
    }

    /// A rollback to a version from before the list reads the old key: the
    /// oldest take is there, as a single record that version understands.
    func testTheOldKeyStillHoldsTheOldestTake() {
        var uploads = PendingUploads()
        uploads.add(take("A.m4a"))
        uploads.add(take("B.m4a"))
        uploads.save(to: defaults)
        XCTAssertEqual(PendingUpload.decode(defaults.string(forKey: PendingUploads.legacyKey))?.path, take("A.m4a").path)

        uploads.remove(take("A.m4a"))
        uploads.remove(take("B.m4a"))
        uploads.save(to: defaults)
        XCTAssertNil(defaults.string(forKey: PendingUploads.listKey))
        XCTAssertNil(defaults.string(forKey: PendingUploads.legacyKey))
    }

    /// The upload writes its session from a background thread while the main
    /// thread adds a take: neither change may be lost.
    func testChangesFromTwoThreadsAreNeverLost() {
        let store = PendingUploadStore(defaults: defaults)
        let takes = (0..<200).map { take("Take-\($0).m4a") }
        DispatchQueue.concurrentPerform(iterations: takes.count) { index in
            store.change { $0.add(takes[index]) }
        }
        XCTAssertEqual(Set(store.current.paths), Set(takes.map(\.path)))
    }

    // MARK: - Uploading by itself

    private func situation(cloudOn: Bool = true, idle: Bool = true, dialogUp: Bool = false,
                           networkReady: Bool = true, lastStart: Date? = nil, now: Date = Date()) -> AutomaticUpload.Situation {
        AutomaticUpload.Situation(cloudOn: cloudOn, idle: idle, dialogUp: dialogUp, networkReady: networkReady,
                                  lastStart: lastStart, now: now)
    }

    func testAWaitingTakeUploadsByItselfOnlyWhenNothingElseIsGoingOn() {
        XCTAssertTrue(AutomaticUpload.mayStart(situation()))
        XCTAssertFalse(AutomaticUpload.mayStart(situation(cloudOn: false)), "cloud switched off")
        XCTAssertFalse(AutomaticUpload.mayStart(situation(idle: false)), "a take, or another upload")
        XCTAssertFalse(AutomaticUpload.mayStart(situation(dialogUp: true)), "the name prompt, a dialog")
        XCTAssertFalse(AutomaticUpload.mayStart(situation(networkReady: false)), "offline")
    }

    /// A Wi-Fi that flickers does not start an upload at every flicker.
    func testAutomaticStartsAreSpacedOut() {
        let now = Date()
        XCTAssertFalse(AutomaticUpload.mayStart(situation(lastStart: now.addingTimeInterval(-10), now: now)))
        XCTAssertTrue(AutomaticUpload.mayStart(situation(lastStart: now.addingTimeInterval(-AutomaticUpload.minimumGap),
                                                         now: now)))
    }

    func testTheOldestTakeGoesFirstUnlessItIsPutOffOrSpent() throws {
        var uploads = PendingUploads()
        for name in ["A.m4a", "B.m4a", "C.m4a"] {
            uploads.add(take(name))
            try Data().write(to: take(name))
        }
        let exists = { FileManager.default.fileExists(atPath: $0) }
        XCTAssertEqual(AutomaticUpload.next(in: uploads, skipped: [], attempts: [:], exists: exists)?.path,
                       take("A.m4a").path)
        // SKIP at launch: not before the next launch.
        XCTAssertEqual(AutomaticUpload.next(in: uploads, skipped: [take("A.m4a").path], attempts: [:], exists: exists)?.path,
                       take("B.m4a").path)
        // A take that failed by itself three times waits for the guest, or the next launch.
        XCTAssertEqual(AutomaticUpload.next(in: uploads, skipped: [],
                                            attempts: [take("A.m4a").path: AutomaticUpload.maximumAttempts],
                                            exists: exists)?.path,
                       take("B.m4a").path)
        try FileManager.default.removeItem(at: take("B.m4a"))
        XCTAssertEqual(AutomaticUpload.next(in: uploads, skipped: [take("A.m4a").path], attempts: [:], exists: exists)?.path,
                       take("C.m4a").path)
        XCTAssertNil(AutomaticUpload.next(in: uploads, skipped: Set(uploads.paths), attempts: [:], exists: exists))
    }

    // MARK: - Words

    func testTheFaceplateCountsTheTakesWaiting() {
        XCTAssertEqual(RecorderViewModel.waitingUploadsLine(1), "1 recording waiting to upload")
        XCTAssertEqual(RecorderViewModel.waitingUploadsLine(3), "3 recordings waiting to upload")
    }

    func testTheFailedCardSaysWhatLaterDoes() {
        XCTAssertTrue(FaceplateUploadFailedView.message(canPutOff: true).contains("Later to keep recording"))
        XCTAssertFalse(FaceplateUploadFailedView.message(canPutOff: false).contains("Later"))
    }
}

