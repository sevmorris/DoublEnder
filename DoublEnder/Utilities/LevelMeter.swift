import Foundation
import Accelerate

/// Shared level-meter parameters for Local, Cloud, and branded builds.
///
/// All flavours compile the same `DoublEnder/` core (`AudioEngine` publishes
/// `meterLevel` and `isClipping`; `FaceplateMeterRow` renders them). Keep
/// floor, ceiling, and smoothing constants here so the engine clamp and
/// viewport scale never drift.
enum LevelMeter {
    static let dbFloor: Float = -48
    static let dbCeiling: Float = 0
    static let segmentCount = 40

    /// Peak-hold ballistics at ~15 ms buffers: instant rise, ~250 ms fall.
    static let peakAttack: Float = 1.0
    static let peakRelease: Float = 0.12

    /// Linear full-scale threshold for the CLIP latch (~−0.09 dBFS).
    static let clipThresholdLinear: Float = 0.99
    /// How long the CLIP indicator stays lit after a peak at full scale.
    static let clipIndicatorHoldDuration: TimeInterval = 3.0

    static let scaleLabels: [(Float, String)] = [
        (dbFloor, "-48"), (-36, "-36"), (-24, "-24"),
        (-12, "-12"), (-6, "-6"), (dbCeiling, "0")
    ]

    static func dbFS(fromLinear linear: Float) -> Float {
        linear > 1e-9 ? 20.0 * log10f(linear) : dbFloor
    }

    static func clampedDisplayDB(fromLinear linear: Float) -> Float {
        max(dbFloor, min(dbCeiling, dbFS(fromLinear: linear)))
    }

    static func isClipping(peakLinear: Float) -> Bool {
        peakLinear >= clipThresholdLinear
    }

    /// Peak linear level across normalized mono samples (max abs, not RMS).
    static func peakLinear(in samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var peak: Float = 0
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            vDSP_maxmgv(base, 1, &peak, vDSP_Length(buf.count))
        }
        return peak
    }
}
