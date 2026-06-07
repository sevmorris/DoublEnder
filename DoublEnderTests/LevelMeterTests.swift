import XCTest
@testable import DoublEnder

final class LevelMeterTests: XCTestCase {

    func testPeakLinearFindsMaxAbsSample() {
        let samples: [Float] = [0.1, -0.3, 0.95, -0.2]
        XCTAssertEqual(LevelMeter.peakLinear(in: samples), 0.95, accuracy: 1e-6)
    }

    func testClampedDisplayDBCapsAtCeiling() {
        XCTAssertEqual(LevelMeter.clampedDisplayDB(fromLinear: 1.5), LevelMeter.dbCeiling, accuracy: 1e-6)
    }
}
