import Foundation
import Accelerate

/// Shared level-meter parameters for Local and Cloud builds.
///
/// Both flavours compile the same `DoublEnder/` core (`AudioEngine` publishes
/// `meterLevel`; `FaceplateMeterRow` renders it). Keep floor, ceiling, and
/// smoothing constants here so the engine clamp and viewport scale never
/// drift.
///
/// ## Design intent: signal indicator, not a production meter
///
/// The meter answers one question: "Is audio coming in?" `AudioEngine`
/// feeds it the mono-downmixed signal from `PCMSidecar.normalizedMonoFloatSamples`,
/// so it reflects approximately the same content as the recorded file.
/// It has no gain control and is not intended as a mix reference — the
/// ballistics (instant attack, ~250 ms release) are tuned for a guest who
/// needs to confirm their mic is working, not for a producer setting
/// record levels.
enum LevelMeter {
    static let dbFloor: Float = -36
    static let dbCeiling: Float = 0
    static let segmentCount = 40

    /// Peak-hold ballistics at ~15 ms buffers: instant rise, ~250 ms fall.
    static let peakAttack: Float = 1.0
    static let peakRelease: Float = 0.12

    static let scaleLabels: [(Float, String)] = [
        (dbFloor, "-36"), (-24, "-24"), (-12, "-12"),
        (-6, "-6"), (dbCeiling, "0")
    ]

    static func dbFS(fromLinear linear: Float) -> Float {
        linear > 1e-9 ? 20.0 * log10f(linear) : dbFloor
    }

    static func clampedDisplayDB(fromLinear linear: Float) -> Float {
        max(dbFloor, min(dbCeiling, dbFS(fromLinear: linear)))
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
