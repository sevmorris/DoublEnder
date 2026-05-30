import XCTest
import Accelerate
@testable import DoublEnder

final class LevelMeterTests: XCTestCase {

    func testPeakLinearFindsMaxAbsSample() {
        let samples: [Float] = [0.1, -0.3, 0.95, -0.2]
        XCTAssertEqual(LevelMeter.peakLinear(in: samples), 0.95, accuracy: 1e-6)
    }

    func testClipThresholdAtFullScaleInt16() {
        let peak = Float(32767) / 32768.0
        XCTAssertTrue(LevelMeter.isClipping(peakLinear: peak))
    }

    func testClipThresholdBelowFullScale() {
        XCTAssertFalse(LevelMeter.isClipping(peakLinear: 0.98))
    }

    func testRMSWouldUnderReportClipPeak() {
        // A single clipped sample in a quiet buffer: peak is hot, RMS is not.
        var samples = [Float](repeating: 0.01, count: 512)
        samples[256] = 1.0
        let peak = LevelMeter.peakLinear(in: samples)
        var rms: Float = 0
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            vDSP_rmsqv(base, 1, &rms, vDSP_Length(buf.count))
        }
        XCTAssertTrue(LevelMeter.isClipping(peakLinear: peak))
        XCTAssertLessThan(20.0 * log10f(rms), -0.1)
    }

    func testClampedDisplayDBCapsAtCeiling() {
        XCTAssertEqual(LevelMeter.clampedDisplayDB(fromLinear: 1.5), LevelMeter.dbCeiling, accuracy: 1e-6)
    }
}
