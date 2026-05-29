import Foundation

/// Shared level-meter parameters for Local, Cloud, and branded builds.
///
/// All flavours compile the same `DoublEnder/` core (`AudioEngine` publishes
/// `rmsLevel`; `FaceplateMeterRow` renders it). Keep floor, ceiling, and
/// smoothing constants here so the engine clamp and viewport scale never drift.
enum LevelMeter {
    static let dbFloor: Float = -48
    static let dbCeiling: Float = 0
    static let segmentCount = 40

    /// Per-buffer attack (~80 ms rise) and release (~300 ms fall) at ~15 ms buffers.
    static let attack: Float = 0.35
    static let release: Float = 0.08

    static let scaleLabels: [(Float, String)] = [
        (dbFloor, "-48"), (-36, "-36"), (-24, "-24"),
        (-12, "-12"), (-6, "-6"), (dbCeiling, "0")
    ]
}
