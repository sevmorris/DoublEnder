import XCTest
@testable import DoublEnder

final class InputRankingTests: XCTestCase {

    /// The port the guest of 2026-10-30 recorded through.
    private let dock = InputCandidate(
        uniqueID: "dock", name: "CalDigit Thunderbolt 3 Audio",
        manufacturer: "CalDigit, Inc.", isUSB: true
    )
    private let usbMic = InputCandidate(
        uniqueID: "mic", name: "Shure MV7", manufacturer: "Shure Inc", isUSB: true
    )
    private let interface = InputCandidate(
        uniqueID: "interface", name: "Scarlett 2i2 USB", manufacturer: "Focusrite", isUSB: true
    )

    private func usb(_ name: String, manufacturer: String = "") -> InputCandidate {
        InputCandidate(uniqueID: name, name: name, manufacturer: manufacturer, isUSB: true)
    }

    // MARK: - Mac with no built-in mic, a dock and a real USB mic

    func testStartsOnTheRealMicWhicheverComesFirst() {
        XCTAssertEqual(InputRanking.defaultInput(among: [dock, usbMic]), usbMic)
        XCTAssertEqual(InputRanking.defaultInput(among: [usbMic, dock]), usbMic)
    }

    /// Launch stamps everything it hasn't seen with the same moment, so a dock
    /// and a mic met together tie, and a dock seen later would win outright.
    func testOffersTheRealMicEvenWhenTheDockIsNewer() {
        XCTAssertEqual(
            InputRanking.usbOffer(among: [dock, usbMic], firstSeen: ["dock": 200, "mic": 100]),
            usbMic
        )
        XCTAssertEqual(
            InputRanking.usbOffer(among: [dock, usbMic], firstSeen: ["dock": 100, "mic": 100]),
            usbMic
        )
    }

    // MARK: - Default input

    func testADockAloneIsStillTheDefault() {
        XCTAssertEqual(InputRanking.defaultInput(among: [dock]), dock)
    }

    func testDefaultKeepsDiscoveryOrderAmongRealInputs() {
        XCTAssertEqual(InputRanking.defaultInput(among: [dock, interface, usbMic]), interface)
    }

    func testNoInputsNoDefault() {
        XCTAssertNil(InputRanking.defaultInput(among: []))
    }

    // MARK: - USB offer

    func testADockAloneIsNeverOffered() {
        XCTAssertNil(InputRanking.usbOffer(among: [dock], firstSeen: ["dock": 100]))
    }

    func testNoUSBInputsNoOffer() {
        XCTAssertNil(InputRanking.usbOffer(among: [], firstSeen: [:]))
    }

    func testOfferIsTheNewestRealInput() {
        XCTAssertEqual(
            InputRanking.usbOffer(
                among: [usbMic, interface, dock],
                firstSeen: ["mic": 100, "interface": 200, "dock": 300]
            ),
            interface
        )
    }

    func testAnUnstampedInputLosesToAStampedOne() {
        XCTAssertEqual(
            InputRanking.usbOffer(among: [usbMic, interface], firstSeen: ["interface": 1]),
            interface
        )
    }

    // MARK: - What counts as a dock's port

    func testDockNamesAreRecognized() {
        XCTAssertTrue(InputRanking.isDockPort(dock))
        XCTAssertTrue(InputRanking.isDockPort(usb("CalDigit TS4 Audio - Rear")))
        XCTAssertTrue(InputRanking.isDockPort(usb("OWC Thunderbolt 3 Audio Device")))
        XCTAssertTrue(InputRanking.isDockPort(usb("ThinkPad USB-C Dock Audio")))
        XCTAssertTrue(InputRanking.isDockPort(usb("USB-C Docking Station")))
        XCTAssertTrue(InputRanking.isDockPort(usb("USB-C Hub Audio")))
        XCTAssertTrue(InputRanking.isDockPort(usb("USB Audio", manufacturer: "CalDigit, Inc.")))
    }

    func testRealInputsAreNotDockPorts() {
        XCTAssertFalse(InputRanking.isDockPort(usbMic))
        XCTAssertFalse(InputRanking.isDockPort(interface))
        XCTAssertFalse(InputRanking.isDockPort(usb("Studio Display Microphone", manufacturer: "Apple Inc.")))
        XCTAssertFalse(InputRanking.isDockPort(usb("Yeti Stereo Microphone")))
        XCTAssertFalse(InputRanking.isDockPort(usb("Haddock Mic")), "Whole words only")
        XCTAssertFalse(InputRanking.isDockPort(usb("Shub 100")), "Whole words only")
    }

    /// An Apollo has Thunderbolt transport, so its name doesn't count against it.
    func testAThunderboltInterfaceIsNotADockPort() {
        let apollo = InputCandidate(
            uniqueID: "apollo", name: "Universal Audio Thunderbolt",
            manufacturer: "Universal Audio", isUSB: false
        )
        XCTAssertFalse(InputRanking.isDockPort(apollo))
        XCTAssertEqual(InputRanking.defaultInput(among: [apollo, usbMic]), apollo)
    }
}
