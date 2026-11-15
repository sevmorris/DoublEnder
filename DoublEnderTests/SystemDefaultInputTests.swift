import XCTest
@testable import DoublEnder

/// The Mac's system default input belongs to the guest and their other apps.
/// Until 2026-11-15 every pick, and so every launch (which picks the built-in
/// mic), moved it: a guest already in a call on a USB mic, with the call app
/// following the default, dropped to the laptop mic.
final class SystemDefaultInputTests: XCTestCase {

    /// The session that `start()` builds (TRY AGAIN, `finishReset`) goes back
    /// on the guest's pick. It used to take the system default, which was the
    /// pick only because the pick had been made the default; left alone, the
    /// default may be the USB mic the call is on.
    func testARebuildWithoutADeviceGoesBackOnThePick() {
        XCTAssertEqual(
            AudioEngine.restartInputUID(requested: "builtin", connected: ["usb-mic", "builtin"]),
            "builtin"
        )
    }

    /// With nothing picked, or the pick unplugged, it is the system default.
    func testARebuildFallsToTheSystemDefaultOnlyWithoutAConnectedPick() {
        XCTAssertNil(AudioEngine.restartInputUID(requested: nil, connected: ["usb-mic", "builtin"]))
        XCTAssertNil(AudioEngine.restartInputUID(requested: "usb-mic", connected: ["builtin"]))
        XCTAssertNil(AudioEngine.restartInputUID(requested: "builtin", connected: []))
    }

    /// No app source sets a system default device. A test can't watch the app
    /// do it without letting it really move this Mac's default, so this reads
    /// the source instead: any mention of the default-device selectors fails,
    /// and a legitimate one (reading the default, say) belongs on the list
    /// below with the reason.
    func testNoAppSourceTouchesTheSystemDefaultDevices() throws {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // DoublEnderTests
            .deletingLastPathComponent()      // the checkout
            .appendingPathComponent("DoublEnder")
        let selectors = [
            "kAudioHardwarePropertyDefaultInputDevice",
            "kAudioHardwarePropertyDefaultOutputDevice",
            "kAudioHardwarePropertyDefaultSystemOutputDevice",
        ]
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil)
        )
        var checked = 0
        var offenders: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            checked += 1
            for selector in selectors where text.contains(selector) {
                offenders.append("\(file.lastPathComponent): \(selector)")
            }
        }
        XCTAssertGreaterThan(checked, 10, "found no app sources at \(appSources.path)")
        XCTAssertEqual(offenders, [], "the app must not set the Mac's default audio devices")
    }
}
