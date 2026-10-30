import XCTest
import AppKit
@testable import DoublEnder

/// The signals here are stand-ins. The thresholds were set against real tracks:
/// the mixed and per-host stems of a 75-minute show, each at its own level, and
/// the mix turned down until its words peaked near -40 dB.
final class VoiceDetectorTests: XCTestCase {
    private static let sampleRate = 48_000.0

    /// Repeatable noise: a test that fails must fail the same way every run.
    private struct Noise {
        private var state: UInt64 = 0x1234_5678

        mutating func next(level: Float) -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(state >> 40) / Float(1 << 24)
            return (unit * 2 - 1) * level
        }
    }

    private var noise = Noise()

    private func noise(seconds: Double, level: Float = 0.001) -> [Float] {
        (0..<Int(seconds * Self.sampleRate)).map { _ in noise.next(level: level) }
    }

    /// Words over noise: bursts of tone at about the rate people speak, with
    /// pauses down to the noise between them.
    private func speech(seconds: Double, level: Float = 0.1, noiseLevel: Float = 0.001) -> [Float] {
        (0..<Int(seconds * Self.sampleRate)).map { index in
            let time = Double(index) / Self.sampleRate
            let inWord = time.truncatingRemainder(dividingBy: 0.8) < 0.4
            let tone = inWord ? level * Float(sin(2 * .pi * 220 * time)) : 0
            return tone + noise.next(level: noiseLevel)
        }
    }

    private func status(_ feed: [[Float]]) -> VoiceDetector.Status {
        var detector = VoiceDetector()
        for samples in feed {
            // In buffers, as capture delivers them.
            stride(from: 0, to: samples.count, by: 1024).forEach { start in
                detector.process(Array(samples[start..<min(start + 1024, samples.count)]), sampleRate: Self.sampleRate)
            }
        }
        return detector.status
    }

    // MARK: - What isn't a voice

    /// The take this exists for: an input with nothing on it, at any gain.
    func testNoiseAloneIsNotAVoice() {
        for level: Float in [0.0001, 0.001, 0.01, 0.1] {
            let result = status([noise(seconds: 30, level: level)])
            XCTAssertFalse(result.heard, "Noise at \(level)")
            XCTAssertEqual(result.secondsWithoutVoice, 30)
        }
    }

    func testDigitalSilenceIsNotAVoice() {
        XCTAssertFalse(status([[Float](repeating: 0, count: Int(30 * Self.sampleRate))]).heard)
    }

    /// Mains hum holds its level as steadily as hiss does.
    func testHumIsNotAVoice() {
        let hum = (0..<Int(30 * Self.sampleRate)).map { Float(0.05 * sin(2 * .pi * 60 * Double($0) / Self.sampleRate)) }
        XCTAssertFalse(status([hum]).heard)
    }

    /// A fan starting up, or someone turning up the gain: one step, one onset.
    func testAStepInTheNoiseIsNotAVoice() {
        XCTAssertFalse(status([noise(seconds: 10, level: 0.0005), noise(seconds: 20, level: 0.05)]).heard)
    }

    /// Dropouts to digital silence, then the noise back, over and over.
    func testNoiseBetweenDropoutsIsNotAVoice() {
        let dropout = [Float](repeating: 0, count: Int(0.3 * Self.sampleRate))
        let feed = (0..<6).flatMap { _ in [noise(seconds: 5, level: 0.005), dropout] }
        XCTAssertFalse(status(feed).heard)
    }

    /// Far too short to be words, however many of them.
    func testClicksAreNotAVoice() {
        var samples = noise(seconds: 30)
        for second in stride(from: 0.0, to: 30.0, by: 0.25) {
            let start = Int(second * Self.sampleRate)
            for index in start..<(start + 240) { samples[index] = 0.3 }
        }
        XCTAssertFalse(status([samples]).heard)
    }

    /// Quieter than anything usable: the shape of speech at -60 dB.
    func testMovementTooQuietToHearIsNotAVoice() {
        XCTAssertFalse(status([speech(seconds: 30, level: 0.001, noiseLevel: 0.00001)]).heard)
    }

    /// A NaN from a driver must not read as a voice, or hide one that follows.
    func testNaNIsNotAVoiceAndDoesNotPoisonWhatFollows() {
        let bad = [Float](repeating: .nan, count: Int(5 * Self.sampleRate))
        XCTAssertFalse(status([bad]).heard)
        XCTAssertTrue(status([bad, speech(seconds: 10)]).heard)
    }

    // MARK: - What is

    func testSpeechIsAVoice() {
        let result = status([speech(seconds: 10)])
        XCTAssertTrue(result.heard)
        XCTAssertLessThan(result.secondsWithoutVoice, 2)
    }

    /// Words 40 dB above nothing much, and words barely 15 dB above loud hiss.
    func testSpeechIsHeardAtLowLevelsAndOverLoudNoise() {
        XCTAssertTrue(status([speech(seconds: 10, level: 0.005, noiseLevel: 0.00005)]).heard)
        XCTAssertTrue(status([speech(seconds: 10, level: 0.2, noiseLevel: 0.03)]).heard)
    }

    /// A long take of noise leaves nothing behind that deafens it to a voice.
    func testSpeechIsHeardAfterALongStretchOfNoise() {
        XCTAssertTrue(status([noise(seconds: 200), speech(seconds: 10)]).heard)
    }

    func testAVoiceThatStopsStartsTheClock() {
        let result = status([speech(seconds: 10), noise(seconds: 30)])
        XCTAssertTrue(result.heard)
        XCTAssertEqual(Double(result.secondsWithoutVoice), 30, accuracy: 6, "The 5 s window can still hold a voice as it ends")
    }

    /// An input that changes rate mid-take keeps its time in seconds.
    func testClockFollowsTheSampleRate() {
        var detector = VoiceDetector()
        detector.process([Float](repeating: 0, count: 480_000), sampleRate: 48_000)
        XCTAssertEqual(detector.status.secondsWithoutVoice, 10)
        detector.process([Float](repeating: 0, count: 80_000), sampleRate: 8_000)
        XCTAssertEqual(detector.status.secondsWithoutVoice, 20)
    }

    func testAZeroSampleRateIsIgnored() {
        var detector = VoiceDetector()
        detector.process([0.5, 0.5], sampleRate: 0)
        XCTAssertEqual(detector.status, VoiceDetector.Status())
    }

    // MARK: - When to warn

    func testWarningComesEarlierForATakeThatNeverHadAVoice() {
        XCTAssertFalse(VoiceDetector.Status(heard: false, secondsWithoutVoice: 119).isWarning)
        XCTAssertTrue(VoiceDetector.Status(heard: false, secondsWithoutVoice: 120).isWarning)
    }

    /// It has to stay up while another app is in front, and take nothing from it.
    func testAlertFloatsOverOtherAppsWithoutTakingFocus() throws {
        defer { NoVoiceAlert.dismiss() }
        NoVoiceAlert.present(heardEarlier: false)
        let panel = try XCTUnwrap(NoVoiceAlert.panel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.floating.rawValue)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertGreaterThan(panel.frame.height, 0, "Sized to its content before it is placed")
    }

    func testAlertCanBeDismissedAndShownAgain() {
        defer { NoVoiceAlert.dismiss() }
        NoVoiceAlert.dismiss()
        XCTAssertNil(NoVoiceAlert.panel, "Dismissing with nothing up does nothing")

        NoVoiceAlert.present(heardEarlier: false)
        let first = NoVoiceAlert.panel
        NoVoiceAlert.present(heardEarlier: true)
        XCTAssertFalse(first?.isVisible ?? true, "A second never stacks on the first")
        XCTAssertNotNil(NoVoiceAlert.panel)

        NoVoiceAlert.dismiss()
        XCTAssertNil(NoVoiceAlert.panel)
    }

    /// One tells a guest to check their input, the other allows they've finished.
    func testAlertWordsFollowTheThresholds() {
        XCTAssertTrue(NoVoiceAlert.message(heardEarlier: false).contains("in 2 minutes"))
        XCTAssertTrue(NoVoiceAlert.message(heardEarlier: true).contains("for 10 minutes"))
        XCTAssertTrue(NoVoiceAlert.message(heardEarlier: true).contains("stop if you're finished"))
    }

    /// A host who is only listening can go five minutes without a word.
    func testWarningWaitsForAListenerOnceAVoiceHasBeenHeard() {
        XCTAssertFalse(VoiceDetector.Status(heard: true, secondsWithoutVoice: 305).isWarning)
        XCTAssertFalse(VoiceDetector.Status(heard: true, secondsWithoutVoice: 599).isWarning)
        XCTAssertTrue(VoiceDetector.Status(heard: true, secondsWithoutVoice: 600).isWarning)
    }
}
