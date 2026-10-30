import Foundation

/// What the launch default and the USB offer need to know about an input.
/// A value type so the choice can be tested without an `AVCaptureDevice`,
/// which a test can't construct.
struct InputCandidate: Equatable {
    let uniqueID: String
    let name: String
    let manufacturer: String
    let isUSB: Bool
}

/// Which input the app starts on or suggests when nobody has chosen one.
///
/// A dock's audio port ranks below every real mic. To CoreAudio it is one more
/// USB input, and with nothing plugged into its jack it still delivers a steady
/// stream of input noise, so the app can't tell it from a mic by transport or
/// by level. A guest on a Mac mini recorded 1 h 6 m of that
/// through "CalDigit Thunderbolt 3 Audio" on 2026-10-30.
///
/// So this goes by name, which `AudioEngine` otherwise avoids, because a wrong
/// answer costs little: a dock's port always stays in the picker, and a mic
/// misread as one is still a click away. A dock whose chip has a generic name
/// ("USB Audio Device") reads as a mic, which is why the offer's wording
/// doesn't promise one.
enum InputRanking {

    /// Distinctive enough to count anywhere in a name.
    private static let dockNameFragments = ["thunderbolt", "caldigit"]
    /// Short enough to turn up inside other words ("Haddock"), so whole words only.
    private static let dockNameWords: Set<String> = ["dock", "docking", "hub"]

    /// True for a USB input whose name or manufacturer says it is a dock's or
    /// a hub's audio port. USB only, and that is what makes "thunderbolt" safe:
    /// a real Thunderbolt interface (an Apollo, say) has Thunderbolt transport,
    /// while a dock's audio chip is a USB device behind the dock's own hub.
    static func isDockPort(_ input: InputCandidate) -> Bool {
        guard input.isUSB else { return false }
        let text = "\(input.name) \(input.manufacturer)".lowercased()
        if dockNameFragments.contains(where: text.contains) { return true }
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.contains(where: dockNameWords.contains)
    }

    /// The input to start on when the Mac has no built-in mic, and to fall back
    /// to when one is lost: the first that isn't a dock's port, in the order
    /// given. With nothing else present it is the dock's port after all, since
    /// a headset may be plugged into it and the engine needs an input to run.
    static func defaultInput(among hardware: [InputCandidate]) -> InputCandidate? {
        hardware.first { !isDockPort($0) } ?? hardware.first
    }

    /// The USB input to offer at launch: the most recently first-seen one that
    /// isn't a dock's port. Never a dock's port, even as the only one. Inputs
    /// with no first-seen stamp count as oldest.
    static func usbOffer(
        among usb: [InputCandidate],
        firstSeen: [String: Double]
    ) -> InputCandidate? {
        usb.filter { !isDockPort($0) }
            .max { (firstSeen[$0.uniqueID] ?? 0) < (firstSeen[$1.uniqueID] ?? 0) }
    }
}
