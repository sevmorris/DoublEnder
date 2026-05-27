import XCTest
@testable import DoublEnder

final class VersionFormattingTests: XCTestCase {

    func testNumericVersionStripsLetterSuffix() {
        XCTAssertEqual(VersionFormatting.numericVersion("1.6.28lr"), "1.6.28")
        XCTAssertEqual(VersionFormatting.numericVersion("1.5.33cr"), "1.5.33")
    }

    func testNumericVersionStripsPreRelease() {
        XCTAssertEqual(VersionFormatting.numericVersion("v2.0.0-beta.1"), "2.0.0")
    }

    func testSplitSuffix() {
        XCTAssertEqual(VersionFormatting.splitSuffix("1.6.28lr").numeric, "1.6.28")
        XCTAssertEqual(VersionFormatting.splitSuffix("1.6.28lr").suffix, "lr")
        XCTAssertEqual(VersionFormatting.splitSuffix("1.6.28").suffix, "")
    }
}
