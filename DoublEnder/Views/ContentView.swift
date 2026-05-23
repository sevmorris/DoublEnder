import SwiftUI
import AVFoundation
import AppKit

// MARK: - Design tokens

/// New window size — matches frame.png aspect ratio (5480 : 4680 ≈ 1.17 : 1).
private let windowSize = CGSize(width: 504, height: 430)

// Viewport insets — identical to CloudContentView so Local and Cloud share
// the same viewport geometry; only the faceplate image differs.
//   top bezel:    79 pt
//   bottom bezel: 81 pt
//   left bezel:   91 pt
//   right bezel:  90 pt
private let vpTop:      CGFloat = 79
private let vpLeading:  CGFloat = 91
private let vpTrailing: CGFloat = 90
private let vpBottom:   CGFloat = 81

// Warm amber palette — mirrors the CloudContentView screen aesthetic.
/// Warm amber (#FFD580) — clock digits, title text.
private let vpAmber  = Color(red: 0xFF/255, green: 0xD5/255, blue: 0x80/255)
/// Amber card-edge stroke (#FFB347 @40%).
private let vpBorder = Color(red: 0xFF/255, green: 0xB3/255, blue: 0x47/255).opacity(0.40)
/// Near-black warm background (#0D0800).
private let vpSurface = Color(red: 0x0D/255, green: 0x08/255, blue: 0x00/255)
/// Amber field stroke (#FFB347 @28%).
private let panelStroke    = Color(red: 0xFF/255, green: 0xB3/255, blue: 0x47/255).opacity(0.28)
/// Dark warm secondary surface (#180E00).
private let secondarySurface = Color(red: 0x18/255, green: 0x0E/255, blue: 0x00/255)
/// Warm off-white body text (#E8D8C0).
private let secondaryText    = Color(red: 0xE8/255, green: 0xD8/255, blue: 0xC0/255)
/// Very dark warm field background (#0D0800).
private let secondaryFieldBg = Color(red: 0x0D/255, green: 0x08/255, blue: 0x00/255)
/// VU meter colour zones — identical to CloudContentView.
private let meterSafe     = Color(red: 0xF5/255, green: 0xA6/255, blue: 0x23/255)  // #F5A623
private let meterWarning  = Color(red: 0xFF/255, green: 0x8C/255, blue: 0x00/255)  // #FF8C00
private let meterDanger   = Color(red: 0xE0/255, green: 0x5C/255, blue: 0x1A/255)  // #E05C1A
private let meterClipRed  = Color(red: 0xCC/255, green: 0x00/255, blue: 0x00/255)  // #CC0000
private let meterInactive = Color(red: 0x2A/255, green: 0x1A/255, blue: 0x00/255)  // #2A1A00

// MARK: - CRT font helper

/// DSEG7 Classic — seven-segment font for the counter only.
/// Registered at launch from the bundled TTF in Resources/Fonts/.
private func crtFont(size: CGFloat) -> Font {
    if NSFont(name: "DSEG7Classic-Regular", size: size) != nil {
        return .custom("DSEG7Classic-Regular", size: size)
    }
    return .system(size: size, weight: .bold, design: .monospaced)
}

/// Clean panel font — Eurostile Bold or SF Pro — for the RECORD/STOP button
/// and any other viewport label that should NOT render as seven-segment.
private func panelFont(size: CGFloat) -> Font {
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
private func handelFont(size: CGFloat) -> Font {
    let candidates = ["HandelGothicBT-Regular", "Handel Gothic",
                      "EurostileLTStd-BoldCn", "DINCondensed-Bold"]
    for name in candidates where NSFont(name: name, size: size) != nil {
        return .custom(name, size: size)
    }
    return .system(size: size, weight: .light, design: .default)
}

/// Inner padding on all four sides of the viewport; content width derived from it.
private let vpInnerPad:     CGFloat = 14
/// (504 − 91 − 90) − 14 − 14 = 295 pt — matches Cloud.
private let vpContentWidth: CGFloat = 295

// MARK: - NSPopover manager

/// Owns both NSPopovers so they float outside the borderless window.
/// Transient — dismissed automatically when the user clicks elsewhere.
@MainActor
private final class PopoverManager: NSObject, ObservableObject, NSPopoverDelegate {
    @Published private(set) var showingInput    = false
    @Published private(set) var showingSettings = false

    private var inputPop:    NSPopover?
    private var settingsPop: NSPopover?
    /// The app window that owns the anchor buttons. Captured when a popover
    /// opens so popoverDidClose can re-activate it without relying on
    /// NSApp.keyWindow, which may still reference the closing popover panel.
    private weak var anchoredWindow: NSWindow?

    /// Opens the input-device popover to the LEFT of the app window.
    /// Uses the button's own NSView to locate the vertical position and
    /// anchors to the window's left edge so the popover never overlaps
    /// the faceplate regardless of where the window sits on screen.
    func toggleInput(buttonView: NSView, content: AnyView) {
        if inputPop != nil { closeInput(); return }
        settingsPop?.close()
        guard let windowView = buttonView.window?.contentView else { return }
        anchoredWindow = buttonView.window
        let btnInWindow = buttonView.convert(buttonView.bounds, to: windowView)
        // Zero-width anchor at x=0 forces the popover fully left of the window.
        let anchor = NSRect(x: 0, y: btnInWindow.minY, width: 0, height: btnInWindow.height)
        let p = makePop(content)
        p.show(relativeTo: anchor, of: windowView, preferredEdge: .minX)
        inputPop = p; showingInput = true
    }

    /// Opens the settings popover to the RIGHT of the app window.
    func toggleSettings(buttonView: NSView, content: AnyView) {
        if settingsPop != nil { closeSettings(); return }
        inputPop?.close()
        guard let windowView = buttonView.window?.contentView else { return }
        anchoredWindow = buttonView.window
        let btnInWindow = buttonView.convert(buttonView.bounds, to: windowView)
        // Zero-width anchor at the window's right edge forces the popover fully right.
        let anchor = NSRect(x: windowView.bounds.width, y: btnInWindow.minY,
                            width: 0, height: btnInWindow.height)
        let p = makePop(content)
        p.show(relativeTo: anchor, of: windowView, preferredEdge: .maxX)
        settingsPop = p; showingSettings = true
    }

    func closeInput()    { inputPop?.close() }
    func closeSettings() { settingsPop?.close() }

    private func makePop(_ content: AnyView) -> NSPopover {
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        p.contentViewController = NSHostingController(rootView: content)
        return p
    }

    func popoverDidClose(_ notification: Notification) {
        guard let p = notification.object as? NSPopover else { return }
        if p === inputPop    { showingInput = false;    inputPop = nil }
        if p === settingsPop { showingSettings = false; settingsPop = nil }
        // Re-activate the app window so the next button tap registers without
        // requiring cursor movement. After a transient NSPopover closes, the
        // borderless window can be left in a deferred-activation state where
        // isMovableByWindowBackground drag tracking intercepts the next click.
        // makeKeyAndOrderFront flushes that state and restores clean hit-testing.
        anchoredWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - ContentView

struct ContentView: View {
    @ObservedObject private var viewModel = RecorderViewModel.shared
    @State private var isStopping = false
    @StateObject private var popovers = PopoverManager()
    /// Drives the RECORD-button red pulse.
    @State private var ledFlashOn = false

    private let flashPublisher = Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // 1 ── Viewport background — padded to the cutout area ONLY so
            //      the window is transparent outside frame.png (no black box).
            viewportBackground
                .padding(EdgeInsets(
                    top: vpTop, leading: vpLeading,
                    bottom: vpBottom, trailing: vpTrailing
                ))

            // 2 ── State-switched content, padded to the viewport cutout
            content
                .padding(EdgeInsets(
                    top: vpTop, leading: vpLeading,
                    bottom: vpBottom, trailing: vpTrailing
                ))

            // 3 ── Faceplate overlay (transparent cutout reveals content)
            Image("del_faceplate")
                .resizable()
                .frame(width: windowSize.width, height: windowSize.height)
                .allowsHitTesting(false)

            // 3.5 ── Diamond badge — sits on the faceplate's top bezel, centred.
            //        Source is 750×640 (1.17:1); rendered at 66×56 pt with top
            //        edge at y=6 (6 pt of bezel above) — fully inside the 79 pt
            //        top bezel and clear of the screen cutout at y=79.
            Image("de_badge")
                .resizable()
                .scaledToFit()
                .frame(width: 66, height: 56)
                .position(x: windowSize.width / 2, y: 34)
                .allowsHitTesting(false)

            // 4 ── Screen glow — amber light spills from cutout onto inner bezel.
            screenGlow

            // 5 ── LED — blinks on the shared 0.75 s timer while recording;
            //      dark/off when idle. Identical position and size to
            //      CloudContentView: bottom-right bezel, x-centred below the
            //      CLIP indicator (x = 383, y = 390).
            Image(isRecordingState && ledFlashOn ? "led_on" : "led_off")
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .position(x: 383, y: 390)
                .allowsHitTesting(false)

            // 6 ── Version overlay — below the baked "DoublEnder" text in the
            //      lower-left bezel. Identical padding to Cloud.
            versionOverlay
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 94)
                .padding(.bottom, 21)
                .allowsHitTesting(false)
        }
        .frame(width: windowSize.width, height: windowSize.height)
        .background(Color.clear)
        .ignoresSafeArea()
        .onReceive(flashPublisher) { _ in
            if isRecordingState { ledFlashOn.toggle() }
            else { ledFlashOn = false }
        }
    }

    // MARK: - Viewport background

    /// Near-black warm surface with scanlines and radial vignette — matches Cloud screen aesthetic.
    private var viewportBackground: some View {
        ZStack {
            vpSurface
            Canvas { context, size in
                let lineSpacing: CGFloat = 3
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(
                        Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                        with: .color(.black.opacity(0.07))
                    )
                    y += lineSpacing
                }
            }
            .allowsHitTesting(false)
            RadialGradient(colors: [.clear, .black.opacity(0.52)],
                           center: .center, startRadius: 80, endRadius: 215)
            .allowsHitTesting(false)
        }
    }

    /// Amber screen glow — a faint lit rectangle whose shadow bleeds outward
    /// onto the inner bezel, simulating warm light spilling from the screen cutout.
    private var screenGlow: some View {
        Rectangle()
            .fill(Color(red: 0xC9/255, green: 0x6A/255, blue: 0x00/255).opacity(0.04))
            .padding(EdgeInsets(top: vpTop, leading: vpLeading,
                                bottom: vpBottom, trailing: vpTrailing))
            .shadow(color: Color(red: 0xC9/255, green: 0x6A/255, blue: 0x00/255).opacity(0.40), radius: 18)
            .allowsHitTesting(false)
    }

    // MARK: - State switch

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .selectingMic, .ready, .recording:
            mainView
        #if GCS_ENABLED
        case .uploading:
            uploadingView
        case .uploadFailed(let url):
            uploadFailedView(url)
        #endif
        case .error(let message):
            errorView(message)
        }
    }

    // MARK: - Main layout

    private var mainView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: vpInnerPad)
            counterWindow
            warningBadge
            Spacer(minLength: 10)
            recordStopButton
            Spacer(minLength: 10)
            MeterRow(
                level: viewModel.rmsLevel,
                inputActive: popovers.showingInput,
                settingsActive: popovers.showingSettings,
                onInputTap: { anchorView in
                    popovers.toggleInput(
                        buttonView: anchorView,
                        content: AnyView(DevicePickerPopover(
                            microphones: viewModel.inputDeviceGroups.microphones,
                            virtualDevices: viewModel.inputDeviceGroups.virtual,
                            selectedID: viewModel.selectedInputDeviceID,
                            onSelect: { id in
                                viewModel.selectedInputDeviceID = id
                                popovers.closeInput()
                            }
                        ))
                    )
                },
                onSettingsTap: { anchorView in
                    popovers.toggleSettings(
                        buttonView: anchorView,
                        content: AnyView(SettingsPopover(viewModel: viewModel))
                    )
                }
            )
            Spacer(minLength: vpInnerPad)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Counter window

    private var counterWindow: some View {
        ZStack {
            vpSurface
            Text(viewModel.recordingTime.hhmmss)
                .font(crtFont(size: 41))
                .tracking(3)
                .foregroundColor(vpAmber)
                .shadow(color: Color(red: 0xF5/255, green: 0xA6/255, blue: 0x23/255).opacity(0.90), radius: 8)
                .shadow(color: Color(red: 0xC8/255, green: 0x78/255, blue: 0x00/255).opacity(0.50), radius: 22)
        }
        .frame(width: vpContentWidth, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(vpBorder, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
    }

    // MARK: - Warning badge

    @ViewBuilder private var warningBadge: some View {
        if let msg = viewModel.recordingWarning {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text(msg)
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.4)
            }
            .foregroundColor(.yellow.opacity(0.80))
            .frame(height: 14)
            .padding(.top, 3)
        }
    }

    // MARK: - RECORD / STOP button

    private var isRecordingState: Bool {
        if case .recording = viewModel.state { return true }
        return false
    }

    private var recordStopButton: some View {
        Button { handleRecordTap() } label: {
            ZStack {
                // Fill = something is happening. Idle/ready: near-transparent
                // dark bg + amber outline. Active/recording: burnt-orange fill.
                RoundedRectangle(cornerRadius: 6)
                    .fill(isRecordingState
                          ? Color(red: 0xBC/255, green: 0x38/255, blue: 0x18/255)  // #BC3818 STOP — warm red, brown undertones
                          : Color(red: 0x1A/255, green: 0x0A/255, blue: 0x00/255)) // #1A0A00 idle
                Text(isRecordingState ? "STOP" : "RECORD")
                    .font(panelFont(size: 41))
                    .tracking(3)
                    .foregroundColor(isRecordingState
                                     ? .white
                                     : Color(red: 0xE5/255, green: 0x5F/255, blue: 0x25/255)) // #E55F25 RECORD — red-amber, hue-shifted toward STOP
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .multilineTextAlignment(.center)
                    // Cap-only text sits optically high; nudge down for the
                    // descender whitespace the font reserves below baseline.
                    .offset(y: 6)
            }
            .frame(width: vpContentWidth, height: 72)
            .background(vpSurface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isRecordingState
                            ? vpBorder
                            : Color(red: 0xE5/255, green: 0x5F/255, blue: 0x25/255), // #E55F25 RECORD outline
                        lineWidth: isRecordingState ? 1.5 : 2.0
                    )
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isStopping)
    }

    private func handleRecordTap() {
        switch viewModel.state {
        case .recording:
            guard !isStopping else { return }
            isStopping = true
            viewModel.stopRecording { isStopping = false }
        case .selectingMic, .ready:
            viewModel.startRecording()
        default:
            break
        }
    }

    // MARK: - Version overlay

    /// Dynamic version number rendered below the baked app-name text in
    /// del_faceplate.png. Identical typography to CloudContentView.
    private var versionOverlay: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return Text("v\(version)")
            .font(handelFont(size: 14))
            .fontWeight(.thin)
            .foregroundColor(Color(red: 0x18/255, green: 0x18/255, blue: 0x18/255))
            .shadow(color: .white.opacity(0.10), radius: 0, x: 0, y: 1)
            .opacity(0.65)
    }

    // MARK: - Secondary state views

    #if GCS_ENABLED
    private var uploadingView: some View {
        SecondaryCard {
            VStack(spacing: 12) {
                Text("Uploading…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(secondaryText)
                ProgressView(value: viewModel.uploadProgress)
                    .progressViewStyle(.linear)
                    .tint(vpAmber)
                    .frame(width: 168)
                Text("\(Int(viewModel.uploadProgress * 100))%")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(secondaryText)
                    .monospacedDigit()
            }
        }
    }

    private func uploadFailedView(_ url: URL) -> some View {
        SecondaryCard {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.icloud.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(vpAmber)
                Text("Recording saved to Desktop. Upload failed — tap Retry to try again.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                SecondaryButton("RETRY UPLOAD") { viewModel.retryUpload() }
            }
        }
    }
    #endif

    private func errorView(_ message: String) -> some View {
        SecondaryCard {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(vpAmber)
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                SecondaryButton("TRY AGAIN") { viewModel.reset() }
            }
        }
    }
}

// MARK: - Meter row (input button + level meter + settings button — detached)

/// Three independent controls in a single horizontal zone at the bottom of
/// the viewport: input-selector button (own border), level meter with CLIP
/// (own border, dBFS labels under it), settings button (own border). Gaps
/// between elements make each read as a standalone tappable control rather
/// than a fused chrome strip.
///
/// Layout (sum to vpContentWidth = 295 pt):
///   input box (34) | gap (6) | meter (215 = 181 canvas + 34 CLIP) | gap (6) | settings box (34)
///
/// HStack alignment is .top — the icon buttons line up with the meter's
/// bar; the meter's dBFS labels dangle below at their canvas-only width.
///
/// The popover-trigger logic lives outside this view — the caller passes
/// closures invoked with the captured NSView so NSPopover can anchor to it.
private struct MeterRow: View {
    let level: Float                            // -60 … 0 dBFS
    let inputActive: Bool                       // popover currently open?
    let settingsActive: Bool
    var onInputTap:    (NSView) -> Void
    var onSettingsTap: (NSView) -> Void

    @State private var inputAnchor:    NSView?
    @State private var settingsAnchor: NSView?

    private static let segCount = 40
    private static let dbMin: Float = -60
    private static let dbMax: Float =   0

    var body: some View {
        let containerH: CGFloat = 34
        let iconBoxW:   CGFloat = 34
        let gap:        CGFloat = 6
        let clipW:      CGFloat = 34
        // meterW absorbs the rest: 295 − (2·34 + 2·6) = 215 pt
        let meterW:     CGFloat = vpContentWidth - (iconBoxW * 2) - (gap * 2)
        let canvasW:    CGFloat = meterW - clipW   // 181 pt
        let clipping   = level >= -0.1

        HStack(alignment: .top, spacing: gap) {
            iconButton(
                name: "input_icon",
                active: inputActive,
                width: iconBoxW, height: containerH,
                help: "Select input device",
                capture: { inputAnchor = $0 },
                onTap: { if let av = inputAnchor { onInputTap(av) } }
            )
            meterUnit(meterW: meterW, canvasW: canvasW, clipW: clipW,
                      containerH: containerH, clipping: clipping)
            iconButton(
                name: "settings_icon",
                active: settingsActive,
                width: iconBoxW, height: containerH,
                help: "Settings",
                capture: { settingsAnchor = $0 },
                onTap: { if let av = settingsAnchor { onSettingsTap(av) } }
            )
        }
        .frame(width: vpContentWidth)
    }

    /// Standalone meter unit: bordered container with segment bar + CLIP cell,
    /// dBFS labels stacked below. Extracted from the row body so the Swift
    /// type-checker can finish in reasonable time.
    @ViewBuilder
    private func meterUnit(
        meterW: CGFloat,
        canvasW: CGFloat,
        clipW: CGFloat,
        containerH: CGFloat,
        clipping: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Canvas { ctx, size in
                    let n = Self.segCount
                    let segGap: CGFloat = 1.5
                    let inset:  CGFloat = 3
                    let availW = size.width - inset * 2
                    let availH = size.height - inset * 2
                    let sw = (availW - CGFloat(n - 1) * segGap) / CGFloat(n)
                    for i in 0..<n {
                        let db  = Self.dbMin + Float(i) / Float(n) * (Self.dbMax - Self.dbMin)
                        let lit = level >= db
                        // Colour zones: amber ≤ −18 | orange ≤ −6 | red > −6
                        let base: Color
                        if      db < -18 { base = meterSafe    }
                        else if db <  -6 { base = meterWarning }
                        else             { base = meterDanger   }
                        let c = lit ? base : meterInactive
                        let x = inset + CGFloat(i) * (sw + segGap)
                        let rect = CGRect(x: x, y: inset, width: max(sw, 1), height: availH)
                        ctx.fill(RoundedRectangle(cornerRadius: 1).path(in: rect), with: .color(c))
                    }
                }
                .frame(width: canvasW, height: containerH)

                Text("CLIP")
                    .font(.system(size: 7, weight: .bold))
                    .tracking(0.4)
                    .foregroundColor(clipping ? .white : vpAmber.opacity(0.22))
                    .frame(width: clipW, height: containerH)
                    .background(clipping ? meterClipRed : vpSurface)
            }
            .frame(width: meterW, height: containerH)
            .background(vpSurface)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(vpBorder, lineWidth: 1.2))

            // dBFS scale labels — span only the canvas, not the CLIP cell.
            GeometryReader { _ in
                let labels: [(Float, String)] = [
                    (-60, "-60"), (-48, "-48"), (-36, "-36"),
                    (-24, "-24"), (-12, "-12"), (-6, "-6"), (0, "0")
                ]
                ForEach(0..<labels.count, id: \.self) { i in
                    let (db, text) = labels[i]
                    let frac = CGFloat((db - Self.dbMin) / (Self.dbMax - Self.dbMin))
                    Text(text)
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundColor(vpAmber.opacity(0.55))
                        .position(x: frac * canvasW, y: 5)
                }
            }
            .frame(width: meterW, height: 12)
        }
    }

    /// Standalone tappable amber icon in its own bordered box — matches the
    /// meter's chrome so the row reads as three sibling controls rather than
    /// three regions of one strip. Icon alpha brightens 0.65 → 1.0 when its
    /// popover is open.
    @ViewBuilder
    private func iconButton(
        name: String,
        active: Bool,
        width: CGFloat,
        height: CGFloat,
        help: String,
        capture: @escaping (NSView) -> Void,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            Image(name)
                .resizable()
                .scaledToFit()
                .foregroundColor(vpAmber.opacity(active ? 1.0 : 0.65))
                .frame(width: 20, height: 20)
                .frame(width: width, height: height, alignment: .center)
                .background(vpSurface)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(vpBorder, lineWidth: 1.2))
                .contentShape(Rectangle())
                .background(ViewAnchor { capture($0) })
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(help)
    }
}

// MARK: - NSView capture helper

/// Zero-size NSViewRepresentable that fires `onCapture` with its own NSView
/// on first appearance (and on updates). Used to capture the backing NSView
/// for a SwiftUI button so NSPopover can anchor without touching keyWindow.
///
/// `AnchorView` overrides `mouseDownCanMoveWindow` → false so the borderless
/// window's background-drag tracking doesn't compete with repeated button
/// taps in the same spot.
private struct ViewAnchor: NSViewRepresentable {
    let onCapture: (NSView) -> Void

    func makeNSView(context: Context) -> AnchorView {
        let v = AnchorView()
        DispatchQueue.main.async { onCapture(v) }
        return v
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        DispatchQueue.main.async { onCapture(nsView) }
    }

    final class AnchorView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

// MARK: - Secondary surface components (popovers, error card)

private struct SecondaryCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(secondarySurface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(vpBorder, lineWidth: 1.5)
            )
            .preferredColorScheme(.dark)
    }
}

private struct SecondaryButton: View {
    let label: String
    let action: () -> Void

    init(_ label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundColor(secondaryText)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 4).fill(secondaryFieldBg))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(vpAmber, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

// MARK: - Device picker popover

private struct DevicePickerPopover: View {
    let microphones:    [AVCaptureDevice]
    let virtualDevices: [AVCaptureDevice]
    let selectedID:     String
    let onSelect:       (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !microphones.isEmpty {
                sectionHeader("MICROPHONES", topPadding: 12)
                ForEach(microphones, id: \.uniqueID) { row($0, dimmed: false) }
            }
            if !virtualDevices.isEmpty {
                sectionHeader("VIRTUAL & AGGREGATE", topPadding: microphones.isEmpty ? 12 : 15)
                ForEach(virtualDevices, id: \.uniqueID) { row($0, dimmed: true) }
            }
        }
        .padding(.bottom, 8)
        .frame(minWidth: 275)
        .background(secondarySurface)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(vpBorder, lineWidth: 1.5))
        .preferredColorScheme(.dark)
    }

    private func sectionHeader(_ text: String, topPadding: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(1.5)
            .foregroundColor(vpAmber)
            .padding(.horizontal, 15)
            .padding(.top, topPadding)
            .padding(.bottom, 5)
    }

    private func row(_ device: AVCaptureDevice, dimmed: Bool) -> some View {
        Button { onSelect(device.uniqueID) } label: {
            HStack {
                Text(device.localizedName)
                    .font(.system(size: 14))
                    .foregroundColor(secondaryText.opacity(dimmed ? 0.45 : 1.0))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if selectedID == device.uniqueID {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(vpAmber)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

// MARK: - Settings popover

private struct SettingsPopover: View {
    @ObservedObject var viewModel: RecorderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("SETTINGS")
                .font(.system(size: 13, weight: .bold))
                .tracking(1.8)
                .foregroundColor(vpAmber)

            // Filename
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("FILENAME")
                HStack(spacing: 8) {
                    TextField(RecorderViewModel.defaultRecordingPrefix, text: $viewModel.filenameBase)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundColor(secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(secondaryFieldBg)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(panelStroke, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text("_<date>.\(viewModel.outputFormat.fileExtension)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(secondaryText.opacity(0.55))
                        .fixedSize()
                }
            }

            // Notes
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("NOTES")
                ZStack(alignment: .topLeading) {
                    if viewModel.notes.isEmpty {
                        Text("Saved as metadata in the recording")
                            .font(.system(size: 12))
                            .italic()
                            .foregroundColor(secondaryText.opacity(0.45))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $viewModel.notes)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 14))
                        .foregroundColor(secondaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 4)
                }
                .frame(height: 70)
                .background(secondaryFieldBg)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(panelStroke, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                if viewModel.outputFormat == .wav {
                    Text("Notes are not stored in WAV files.")
                        .font(.system(size: 11))
                        .foregroundColor(secondaryText.opacity(0.55))
                }
            }

            // Format
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("FORMAT")
                Picker("", selection: $viewModel.outputFormat) {
                    ForEach(OutputFormat.allCases) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(vpAmber)
                Text(viewModel.outputFormat == .aac
                     ? "Recorded as mono, 256 kbps. Smaller file size, transparent quality for voice."
                     : "Uncompressed 24-bit PCM at the hardware's native sample rate. Professional quality, universally compatible.")
                    .font(.system(size: 11))
                    .foregroundColor(secondaryText.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 325)
        .background(secondarySurface)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(vpBorder, lineWidth: 1.5))
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(1.2)
            .foregroundColor(vpAmber)
    }
}
