import SwiftUI
import AppKit

// MARK: - Design tokens

enum FaceplateDesign {
    /// New window size — matches frame.png aspect ratio (5480 : 4680 ≈ 1.17 : 1).
    static let windowSize = CGSize(width: 504, height: 430)

    // Viewport insets — identical across Local and Cloud; only the faceplate image differs.
    //   top bezel:    79 pt
    //   bottom bezel: 81 pt
    //   left bezel:   91 pt
    //   right bezel:  90 pt
    static let vpTop:      CGFloat = 79
    static let vpLeading:  CGFloat = 91
    static let vpTrailing: CGFloat = 90
    static let vpBottom:   CGFloat = 81

    /// Warm amber (#FFD580) — clock digits, title text.
    static let vpAmber  = Color(red: 0xFF/255, green: 0xD5/255, blue: 0x80/255)
    /// Amber card-edge stroke (#FFB347 @40%).
    static let vpBorder = Color(red: 0xFF/255, green: 0xB3/255, blue: 0x47/255).opacity(0.40)
    /// Near-black warm background (#0D0800).
    static let vpSurface = Color(red: 0x0D/255, green: 0x08/255, blue: 0x00/255)
    /// Amber field stroke (#FFB347 @28%).
    static let panelStroke    = Color(red: 0xFF/255, green: 0xB3/255, blue: 0x47/255).opacity(0.28)
    /// Dark warm secondary surface (#180E00).
    static let secondarySurface = Color(red: 0x18/255, green: 0x0E/255, blue: 0x00/255)
    /// Warm off-white body text (#E8D8C0).
    static let secondaryText    = Color(red: 0xE8/255, green: 0xD8/255, blue: 0xC0/255)
    /// Very dark warm field background (#0D0800).
    static let secondaryFieldBg = Color(red: 0x0D/255, green: 0x08/255, blue: 0x00/255)

    /// VU meter colour zones.
    static let meterSafe     = Color(red: 0xF5/255, green: 0xA6/255, blue: 0x23/255)  // #F5A623
    static let meterWarning  = Color(red: 0xFF/255, green: 0x8C/255, blue: 0x00/255)  // #FF8C00
    static let meterDanger   = Color(red: 0xE0/255, green: 0x5C/255, blue: 0x1A/255)  // #E05C1A
    static let meterInactive = Color(red: 0x2A/255, green: 0x1A/255, blue: 0x00/255)  // #2A1A00

    /// Inner padding on all four sides of the viewport; content width derived from it.
    static let vpInnerPad:     CGFloat = 14
    /// (504 − 91 − 90) − 14 − 14 = 295 pt.
    static let vpContentWidth: CGFloat = 295

    /// Muted amber #A0600A — version/device label colour in the bottom-row strip.
    static let secondaryAmber = Color(red: 0xA0/255, green: 0x60/255, blue: 0x0A/255)
    /// Dim amber #5A340A — idle WRITING label.
    static let idleWritingAmber = Color(red: 0x5A/255, green: 0x34/255, blue: 0x0A/255)
    /// Bright amber #F5A623 — active WRITING label.
    static let activeAmber = Color(red: 0xF5/255, green: 0xA6/255, blue: 0x23/255)

    /// RECORD button outline / label colour (#E55F25).
    static let recordAccent = Color(red: 0xE5/255, green: 0x5F/255, blue: 0x25/255)
    /// STOP button fill (#BC3818).
    static let stopFill = Color(red: 0xBC/255, green: 0x38/255, blue: 0x18/255)
    /// Idle RECORD button fill (#1A0A00).
    static let recordIdleFill = Color(red: 0x1A/255, green: 0x0A/255, blue: 0x00/255)

    /// Counter digit inner glow (#F5A623 @90%).
    static let counterGlowInner = Color(red: 0xF5/255, green: 0xA6/255, blue: 0x23/255).opacity(0.90)
    /// Counter digit outer glow (#C87800 @50%).
    static let counterGlowOuter = Color(red: 0xC8/255, green: 0x78/255, blue: 0x00/255).opacity(0.50)

    /// Screen glow fill and shadow (#C96A00).
    static let screenGlowColor = Color(red: 0xC9/255, green: 0x6A/255, blue: 0x00/255)

    /// Status LED frame size. The source art is 270 px, so this is a pure
    /// display size — shrinking it needs no new asset.
    static let ledSize: CGFloat = 18
    // The LEDs are not part of the faceplate art — the art carries only the
    // engraved CLOUD / RECORDING labels, and each LED image supplies its own
    // recessed socket and metal ring.
    //
    // x = 422.5 puts the stack under the right-hand screen bezel: measured off
    // the plate, the viewport cutout ends at 413.6 pt and the raised bezel ring
    // runs to 431.5 pt, so at 18 pt the column's right edge lands on the bezel's
    // outer edge and its centre on the ring's midpoint — both readings agree.
    // The y values are the measured vertical centres of the two engraved labels,
    // so each light sits centred beside the word it belongs to.
    // Re-measure all three if the faceplate art moves.
    /// Blue cloud-status LED — beside the CLOUD label (upper).
    static let blueLEDPosition = CGPoint(x: 422.5, y: 381)
    /// Red recording LED — beside the RECORDING label (lower).
    static let redLEDPosition = CGPoint(x: 422.5, y: 400)

    /// Shared typography for the bottom-row metadata strip.
    static let metadataFont = Font.system(size: 8.5, weight: .medium, design: .monospaced)

    static var viewportInsets: EdgeInsets {
        EdgeInsets(
            top: vpTop, leading: vpLeading,
            bottom: vpBottom, trailing: vpTrailing
        )
    }

    /// DSEG7 Classic — seven-segment font for the counter only.
    /// Registered at launch from the bundled TTF in Resources/Fonts/.
    static func crtFont(size: CGFloat) -> Font {
        if NSFont(name: "DSEG7Classic-Regular", size: size) != nil {
            return .custom("DSEG7Classic-Regular", size: size)
        }
        return .system(size: size, weight: .bold, design: .monospaced)
    }

    /// Clean panel font — Eurostile Bold or SF Pro — for the RECORD/STOP button
    /// and any other viewport label that should NOT render as seven-segment.
    static func panelFont(size: CGFloat) -> Font {
        let candidates = [
            "EurostileLTStd-Bold", "Eurostile-Bold", "Eurostile",
            "BankGothicBT-Medium", "BankGothic-Medium", "Bank Gothic"
        ]
        for name in candidates where NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: .bold, design: .default)
    }

    /// Handel Gothic — futuristic technical display font used for the version overlay.
    /// Falls back to Eurostile Bold Condensed then DIN Condensed then system heavy.
    static func handelFont(size: CGFloat) -> Font {
        let candidates = ["HandelGothicBT-Regular", "Handel Gothic",
                          "EurostileLTStd-BoldCn", "DINCondensed-Bold"]
        for name in candidates where NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: .light, design: .default)
    }

    /// Split a version string into its numeric prefix and trailing letter suffix.
    /// Mirrors UpdateChecker.numericVersion's stripping logic.
    static func splitVersionSuffix(_ raw: String) -> (numeric: String, suffix: String) {
        VersionFormatting.splitSuffix(raw)
    }
}
