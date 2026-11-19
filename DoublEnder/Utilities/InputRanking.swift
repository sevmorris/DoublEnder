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

    /// The USB input to offer first at launch: the most recently first-seen one
    /// that isn't a dock's port. Never a dock's port, even as the only one.
    /// Inputs with no first-seen stamp count as oldest.
    static func usbOffer(
        among usb: [InputCandidate],
        firstSeen: [String: Double]
    ) -> InputCandidate? {
        usbOffers(among: usb, firstSeen: firstSeen).first
    }

    /// Every USB input a launch may offer, in the order it offers them: the
    /// most recently first-seen first, ties in the order given, no dock's port
    /// (`LaunchUSBOffers`).
    static func usbOffers(
        among usb: [InputCandidate],
        firstSeen: [String: Double]
    ) -> [InputCandidate] {
        usb.filter { !isDockPort($0) }
            .enumerated()
            .sorted { a, b in
                let seenA = firstSeen[a.element.uniqueID] ?? 0, seenB = firstSeen[b.element.uniqueID] ?? 0
                return seenA != seenB ? seenA > seenB : a.offset < b.offset
            }
            .map(\.element)
    }
}

/// The USB inputs a launch offers, one after another. The first is the newest
/// (`InputRanking.usbOffers`); the next is offered only once the guest has
/// kept the current input over the one before ("Keep Current"), and a switch
/// ends it. Until 2026-11-18 a launch offered only the newest: with a webcam
/// and a USB mic plugged in, Keep Current to the webcam meant the mic was never
/// offered that session, and the guest recorded on the built-in mic unless
/// they found it in the picker.
///
/// An input that cannot be offered when its turn comes (`isWanted`: already
/// the current input, unplugged since launch) is passed over for the one after
/// it. Only Keep Current moves the series on, and an offer that is never shown
/// gets no Keep Current: on a Mac with no built-in mic, which starts on its
/// first hardware input, a webcam that was both that input and the newest
/// stopped the series before the USB mic beside it.
struct LaunchUSBOffers: Equatable {
    private var queue: [String]
    private var offered: String?

    init(_ uids: [String] = []) {
        queue = uids
    }

    /// The first to offer: the first in the queue that `isWanted`.
    mutating func first(isWanted: (String) -> Bool = { _ in true }) -> String? {
        offered = nil
        while !queue.isEmpty {
            let uid = queue.removeFirst()
            if isWanted(uid) {
                offered = uid
                break
            }
        }
        return offered
    }

    /// The guest kept the current input over `uid`: the next to offer that
    /// `isWanted`, when `uid` was the one this launch offered last.
    mutating func next(afterDeclining uid: String, isWanted: (String) -> Bool = { _ in true }) -> String? {
        guard uid == offered else { return nil }
        return first(isWanted: isWanted)
    }

    /// The guest switched, or picked an input themselves: nothing more.
    mutating func stop() {
        queue = []
        offered = nil
    }
}
