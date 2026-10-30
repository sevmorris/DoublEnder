import Foundation

/// Listens to a take for a voice, so an input that delivers only its own noise
/// doesn't go unnoticed until the producer opens the file: a dock's empty jack,
/// a mic left muted at its interface, a cable that has come out.
///
/// The capture watchdogs can't see this. Buffers keep arriving and the file
/// keeps growing, and the meter shows nothing wrong, only nothing at all: its
/// floor is -36 dB, far above the noise of an empty input.
///
/// It tells a voice from noise by how it moves. Noise holds a steady level,
/// however loud the gain has made it; a voice starts and stops, syllable by
/// syllable, well above whatever is underneath it. So over a few seconds of
/// audio, a frame counts as active when it stands clear of the quietest frames
/// there and is loud enough to be worth hearing at all, and a voice is more
/// than one burst of activity, each too long to be a click or a keystroke.
///
/// This hears anything that moves like speech, so a television in the room
/// counts, and it says nothing about what was said. It makes one decision for
/// the app to show, and it keeps no audio.
///
/// Fed from `writerQueue`. Display-only, like the meter: it never affects the
/// recording.
struct VoiceDetector {
    /// Whether a voice has been heard, as of the last whole second of audio.
    struct Status: Equatable {
        var heard = false
        var secondsWithoutVoice = 0

        /// Warn the guest and the producer. It clears itself as soon as a voice
        /// comes back.
        var isWarning: Bool {
            secondsWithoutVoice >= (heard ? VoiceDetector.warnAfterVoiceSeconds : VoiceDetector.warnBeforeVoiceSeconds)
        }
    }

    /// Nothing heard since the take began, which is how a whole take is lost,
    /// so the warning comes early enough to save it.
    static let warnBeforeVoiceSeconds = 120
    /// A voice was heard and has stopped: a cable came out, or the show ended
    /// and nobody pressed STOP. Or the speaker is only listening, and on a real
    /// three-way show (75 minutes, 2026-10-30) hosts went up to 305 s without a
    /// word, passing 60 s 15 times on one track. So this waits well past that.
    static let warnAfterVoiceSeconds = 600

    private static let frameSeconds = 0.05
    /// The frames looked back over, 5 s of them, long enough to hold two of a
    /// speaker's pauses. A change in the noise passes out of them by itself.
    private static let windowFrames = 100
    /// The floor is the level a tenth of those frames are under, not the very
    /// quietest: a dropout to digital silence would otherwise make the noise on
    /// either side of it stand clear of the floor, and read as two bursts.
    private static let floorPercentile = 0.1
    /// A burst of 150 ms, which outlasts a click or a keystroke, and two of
    /// them, which one thump or a step in the noise can't supply.
    private static let minBurstFrames = 3
    private static let minBursts = 2
    /// How far a frame must stand above the floor. The RMS of a 50 ms frame of
    /// steady noise moves well under 1 dB, and speech peaks are 20 dB or more
    /// above its pauses.
    private static let marginDB = 10.0
    /// The quietest frame that counts, about a word peaking near -40 dB, well
    /// below a usable level but still a person. Empty inputs measure far lower.
    private static let quietestVoiceDB = -55.0
    private static let lowestLevelDB = -120.0

    private(set) var status = Status()

    private var frameEnergy = 0.0
    private var frameSamples = 0
    /// The level of each recent frame in dB, as a ring. Unwritten slots hold
    /// nil until the first 5 s have passed.
    private var levels = [Double?](repeating: nil, count: VoiceDetector.windowFrames)
    private var nextLevel = 0
    private var framesSinceVoice = 0

    /// Takes the buffer's mono mix, in the -1…1 range. `sampleRate` is read for
    /// each buffer because an input can change its rate during a take.
    mutating func process(_ samples: [Float], sampleRate: Double) {
        guard sampleRate > 0 else { return }
        let frameLength = max(Int(sampleRate * Self.frameSeconds), 1)
        for sample in samples {
            let value = Double(sample)
            frameEnergy += value * value
            frameSamples += 1
            if frameSamples >= frameLength {
                closeFrame()
            }
        }
    }

    private mutating func closeFrame() {
        let rms = (frameEnergy / Double(frameSamples)).squareRoot()
        frameEnergy = 0
        frameSamples = 0
        // A NaN from a bad driver reads as the quietest frame.
        levels[nextLevel] = rms > 0 && rms.isFinite ? max(20 * log10(rms), Self.lowestLevelDB) : Self.lowestLevelDB
        nextLevel = (nextLevel + 1) % Self.windowFrames

        framesSinceVoice += 1
        if windowHoldsVoice() {
            framesSinceVoice = 0
            status.heard = true
        }
        status.secondsWithoutVoice = Int(Double(framesSinceVoice) * Self.frameSeconds)
    }

    private func windowHoldsVoice() -> Bool {
        let sorted = levels.compactMap { $0 }.sorted()
        guard !sorted.isEmpty else { return false }
        let floor = sorted[Int(Double(sorted.count) * Self.floorPercentile)]
        let threshold = max(floor + Self.marginDB, Self.quietestVoiceDB)
        var bursts = 0
        var burstFrames = 0
        // Oldest first: nextLevel is the next slot to write.
        for offset in 0..<Self.windowFrames {
            if let level = levels[(nextLevel + offset) % Self.windowFrames], level > threshold {
                burstFrames += 1
                if burstFrames == Self.minBurstFrames { bursts += 1 }
            } else {
                burstFrames = 0
            }
        }
        return bursts >= Self.minBursts
    }
}
