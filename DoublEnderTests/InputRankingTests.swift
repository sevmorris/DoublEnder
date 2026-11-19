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

    // MARK: - More than one USB input at launch

    private let webcam = InputCandidate(
        uniqueID: "webcam", name: "Logitech BRIO", manufacturer: "Logitech", isUSB: true
    )

    /// A webcam, a USB mic and a dock: both real inputs are offered, the newest
    /// first, and never the dock.
    func testEveryRealUSBInputIsOfferedNewestFirst() {
        XCTAssertEqual(
            InputRanking.usbOffers(among: [usbMic, dock, webcam],
                                   firstSeen: ["mic": 100, "webcam": 200, "dock": 300]),
            [webcam, usbMic]
        )
        // Unstamped ones come last, in the order given.
        XCTAssertEqual(
            InputRanking.usbOffers(among: [usbMic, interface, webcam], firstSeen: ["webcam": 1]),
            [webcam, usbMic, interface]
        )
    }

    /// Keep Current to the webcam used to end it, and the mic plugged in beside
    /// it was never offered that session. Now the mic is offered next.
    func testKeepCurrentOffersTheNextUSBInput() {
        var offers = LaunchUSBOffers(["webcam", "mic", "interface"])
        XCTAssertEqual(offers.first(), "webcam")
        XCTAssertEqual(offers.next(afterDeclining: "webcam"), "mic")
        XCTAssertEqual(offers.next(afterDeclining: "mic"), "interface")
        XCTAssertNil(offers.next(afterDeclining: "interface"))
    }

    /// A switch, or a pick in the picker, ends it; and a Keep Current to a
    /// USB input plugged in later (not one of the launch's) offers nothing.
    func testASwitchEndsTheLaunchOffers() {
        var offers = LaunchUSBOffers(["webcam", "mic"])
        XCTAssertEqual(offers.first(), "webcam")
        offers.stop()
        XCTAssertNil(offers.next(afterDeclining: "webcam"))

        var other = LaunchUSBOffers(["webcam", "mic"])
        XCTAssertEqual(other.first(), "webcam")
        XCTAssertNil(other.next(afterDeclining: "hot-plugged"))
        XCTAssertEqual(other.next(afterDeclining: "webcam"), "mic")
        var none = LaunchUSBOffers()
        XCTAssertNil(none.first())
    }

    /// A Mac with no built-in mic starts on its first hardware input, here the
    /// webcam, which is also the newest. Its offer can't be shown (it is the
    /// current input), so no Keep Current would ever move the series on: it is
    /// passed over, and the mic is offered first.
    func testAnInputThatCannotBeOfferedIsPassedOver() {
        var offers = LaunchUSBOffers(["webcam", "mic"])
        XCTAssertEqual(offers.first { $0 != "webcam" }, "mic")
        XCTAssertNil(offers.next(afterDeclining: "mic"))

        // Later in the series too: an input unplugged since launch.
        var later = LaunchUSBOffers(["webcam", "gone", "mic"])
        XCTAssertEqual(later.first(), "webcam")
        XCTAssertEqual(later.next(afterDeclining: "webcam") { $0 != "gone" }, "mic")

        // None worth offering: nothing.
        var nothing = LaunchUSBOffers(["webcam"])
        XCTAssertNil(nothing.first { _ in false })
        XCTAssertNil(nothing.next(afterDeclining: "webcam"))
    }

    // MARK: - The alert after losing an input

    func testLosingAnInputNamesWhatItFellBackTo() {
        let builtIn = InputCandidate(
            uniqueID: "builtIn", name: "MacBook Pro Microphone", manufacturer: "Apple Inc.", isUSB: false
        )
        XCTAssertEqual(
            RecorderViewModel.fallbackInputMessage(builtIn, isBuiltIn: true),
            "Switched to the built-in microphone."
        )
        XCTAssertEqual(
            RecorderViewModel.fallbackInputMessage(usbMic, isBuiltIn: false),
            "Switched to Shure MV7."
        )
        XCTAssertEqual(
            RecorderViewModel.fallbackInputMessage(nil, isBuiltIn: false),
            "No other input is available."
        )
    }

    func testFallingBackToADockSaysItIsOne() {
        XCTAssertEqual(
            RecorderViewModel.fallbackInputMessage(dock, isBuiltIn: false),
            "Switched to CalDigit Thunderbolt 3 Audio, a dock's audio port. Choose another input unless your microphone is connected to it."
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

/// What the engine makes of its bound input while no take is in progress.
final class IdleInputCheckTests: XCTestCase {

    func testAConnectedListedInputIsUsable() {
        for notified in [false, true] {
            for rebuilding in [false, true] {
                XCTAssertEqual(AudioEngine.idleInputCheck(boundConnected: true, listedConnected: true,
                                                          lossNotified: notified, rebuilding: rebuilding), .usable)
            }
        }
    }

    /// Gone: the recorder is told once.
    func testALostInputIsReportedOnce() {
        XCTAssertEqual(AudioEngine.idleInputCheck(boundConnected: false, listedConnected: false,
                                                  lossNotified: false, rebuilding: false), .lost)
        XCTAssertEqual(AudioEngine.idleInputCheck(boundConnected: false, listedConnected: false,
                                                  lossNotified: true, rebuilding: false), .stillLost)
        // The object says connected but the list no longer has it.
        XCTAssertEqual(AudioEngine.idleInputCheck(boundConnected: true, listedConnected: false,
                                                  lossNotified: false, rebuilding: false), .lost)
    }

    /// A Mac with no other input: the only microphone unplugged and plugged
    /// back in. The session is bound to an object that will never deliver
    /// again, while the list holds a new one with the same UID. Until the
    /// engine rebuilt on it, the input showed by name over a dead session and
    /// RECORD failed five seconds in.
    func testAnInputThatComesBackIsBoundAgain() {
        XCTAssertEqual(AudioEngine.idleInputCheck(boundConnected: false, listedConnected: true,
                                                  lossNotified: true, rebuilding: false), .returned)
        // Unplugged and back before the first look at the list.
        XCTAssertEqual(AudioEngine.idleInputCheck(boundConnected: false, listedConnected: true,
                                                  lossNotified: false, rebuilding: false), .returned)
    }

    /// The recorder has already asked for another input (its fallback after
    /// the loss): the engine does not put the old one back under it.
    func testARebuildUnderWayIsLeftToWhoeverAskedForIt() {
        XCTAssertEqual(AudioEngine.idleInputCheck(boundConnected: false, listedConnected: true,
                                                  lossNotified: true, rebuilding: true), .stillLost)
        XCTAssertEqual(AudioEngine.idleInputCheck(boundConnected: false, listedConnected: true,
                                                  lossNotified: false, rebuilding: true), .lost)
    }
}
