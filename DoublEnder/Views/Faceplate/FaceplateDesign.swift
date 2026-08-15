import SwiftUI
import AppKit

// MARK: - Design tokens

enum FaceplateDesign {
    /// Global UI scale for the faceplate and everything inside the viewport.
    /// Every geometry and type value below derives from it, so resizing the app
    /// is one number rather than fifteen. Base values are the 1.0 design — a
    /// 504 x 430 window.
    ///
    /// Scaling needs no new art: the faceplate is 5480 px wide, about 11x
    /// oversampled at 1.0. Note that the engraved RECORDING / CLOUD labels are
    /// baked into that art, so they scale WITH the plate — which is why
    /// `ledSize` scales too (see its note), keeping each light in proportion to
    /// the word it labels.
    static let scale: CGFloat = 1.2

    /// Scale a base-design value to the current UI scale.
    static func s(_ v: CGFloat) -> CGFloat { v * scale }

    /// Window size — matches the faceplate aspect ratio (5480 : 4680 ≈ 1.17 : 1).
    static let windowSize = CGSize(width: s(504), height: s(430))

    // Viewport insets — identical across Local and Cloud. Both variants render
    // the SAME shared de_faceplate art; Cloud only adds the de_cloud_label
    // overlay on top, so these insets can never drift between the two.
    //   top bezel:    79 pt
    //   bottom bezel: 81 pt
    //   left bezel:   91 pt
    //   right bezel:  90 pt
    static let vpTop:      CGFloat = s(79)
    static let vpLeading:  CGFloat = s(91)
    static let vpTrailing: CGFloat = s(90)
    static let vpBottom:   CGFloat = s(81)

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
    static let vpInnerPad:     CGFloat = s(14)
    /// (504 − 91 − 90) − 14 − 14 = 295 pt at scale 1.0.
    static let vpContentWidth: CGFloat = s(295)

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

    // MARK: - Faceplate overlays
    //
    // The variant badges and the engraved CLOUD label are authored as
    // full-canvas 5480x4680 transparent PNGs, so they register with the plate
    // exactly and no position has to be measured by hand. They are NOT shipped
    // that way: the system decodes an overlay at full resolution no matter how
    // little of it is ink, which measured at ~98 MB of resident memory each
    // (removing one full-canvas overlay took the app from 350 MB RSS to 242).
    //
    // `tools/crop-overlay.py` crops each export to its ink and emits the
    // constants below — the ink's size and centre in base-design points — so
    // the artwork lands in exactly the same place at roughly 1/60th the image
    // memory. Re-run the tool whenever the art is re-exported; do not hand-edit.

    /// Engraved CLOUD label (Cloud only). Its y is the same value as
    /// `blueLEDPosition`'s — the label and its light sit on one baseline.
    static let cloudLabelSize     = CGSize(width: s(47.36), height: s(10.38))
    static let cloudLabelPosition = CGPoint(x: s(381.63), y: s(380.80))

    /// Status LED frame size. The source art is 270 px, so this is a pure
    /// display size — no asset work to change it.
    ///
    /// Scaled with the app rather than held absolute: the engraved labels are
    /// baked into the plate and therefore grow with it, and what was tuned is
    /// the LED's relationship to its label (~1.8x the cap height). Holding this
    /// at 18 while the labels grew dropped it to ~1.5x and read under-scaled.
    static let ledSize: CGFloat = s(18)

    // The LEDs are not part of the faceplate art — the art carries only the
    // engraved CLOUD / RECORDING labels, and each LED image supplies its own
    // recessed socket and metal ring. All three measurements below are in
    // base-design points, taken off the 5480 x 4680 plate; re-measure them if
    // the art changes.
    //
    /// Outer edge of the raised screen bezel. The viewport cutout ends at
    /// 413.6 and the bezel ring runs to here, so right-aligning the LED column
    /// to it puts the stack under the bezel — and at 18 pt the column's centre
    /// also lands on the ring's midpoint, satisfying both readings of "aligned".
    private static let bezelRightEdge: CGFloat = 431.5
    /// Vertical centres of the two engraved labels, so each light sits beside
    /// the word it belongs to.
    private static let cloudLabelCentreY:     CGFloat = 380.8
    private static let recordingLabelCentreY: CGFloat = 400.2

    /// Column x. Derived, not hard-coded: `ledSize` does not scale while the
    /// plate does, so the right-alignment has to be recomputed per scale.
    private static let ledColumnX: CGFloat = s(bezelRightEdge) - ledSize / 2

    /// Blue cloud-status LED — beside the CLOUD label (upper).
    static let blueLEDPosition = CGPoint(x: ledColumnX, y: s(cloudLabelCentreY))
    /// Red recording LED — beside the RECORDING label (lower).
    static let redLEDPosition = CGPoint(x: ledColumnX, y: s(recordingLabelCentreY))

    /// Shared typography for the bottom-row metadata strip.
    static let metadataFont = Font.system(size: s(8.5), weight: .medium, design: .monospaced)

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
