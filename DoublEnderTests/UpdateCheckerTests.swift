import XCTest
@testable import DoublEnder

/// `minimumMacOS(inReleaseNotes:)` and its helpers decide whether the update
/// check offers a release, from the marker release.sh writes into its notes.
/// A missing or malformed marker sets no minimum, so the release is offered as
/// it always was.
final class UpdateCheckerMinimumMacOSTests: XCTestCase {

    private func version(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    private func fields(_ version: OperatingSystemVersion?) -> [Int]? {
        version.map { [$0.majorVersion, $0.minorVersion, $0.patchVersion] }
    }

    /// The footer release.sh appends after the curated notes.
    func testReadsTheMarkerReleaseShWrites() {
        XCTAssertEqual(fields(UpdateChecker.minimumMacOS(inReleaseNotes: "**Fixed**\n- Something.\n\n---\nRequires macOS 15.0 or later.\n<!-- minimum-macos: 15.0 -->")), [15, 0, 0])
        XCTAssertEqual(fields(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 15.2.1 -->")), [15, 2, 1])
        XCTAssertEqual(fields(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 26 -->")), [26, 0, 0])
    }

    /// A release from before the marker runs on every macOS the installed build
    /// does, and the visible "Requires macOS" line is prose, not the marker.
    func testNotesWithoutAMarkerSetNoMinimum() {
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: nil))
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: "**Fixed**\n- Something."))
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: "Requires macOS 15.0 or later."))
    }

    func testAMalformedMarkerSetsNoMinimum() {
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: fifteen -->"))
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 15.0"))
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 15..0 -->"))
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 1.2.3.4 -->"))
    }

    func testComparesMajorThenMinorThenPatch() {
        XCTAssertFalse(UpdateChecker.runs(on: version(14, 6), given: version(15)))
        XCTAssertTrue(UpdateChecker.runs(on: version(15), given: version(15)))
        XCTAssertTrue(UpdateChecker.runs(on: version(26, 7, 1), given: version(15)))
        XCTAssertFalse(UpdateChecker.runs(on: version(15), given: version(15, 1)))
        XCTAssertTrue(UpdateChecker.runs(on: version(15, 1), given: version(15, 0, 1)))
    }

    func testDescribesAVersionTheWayMacOSDoes() {
        XCTAssertEqual(UpdateChecker.describe(version(15)), "15.0")
        XCTAssertEqual(UpdateChecker.describe(version(15, 2, 1)), "15.2.1")
    }
}
