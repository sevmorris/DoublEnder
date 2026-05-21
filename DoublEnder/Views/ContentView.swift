import SwiftUI
import AVFoundation
import AppKit

// MARK: - Design tokens

/// New window size — matches frame.png aspect ratio (5480 : 4680 ≈ 1.17 : 1).
private let windowSize = CGSize(width: 504, height: 430)

// Viewport insets — derived from exact pixel measurement of frame.png
// (5480×4680 image, transparent cutout at px 985–4508 x, 867–3821 y,
//  scaled to the 420×358 window at 13.05 px/pt).
//   left bezel:  985/13.048  = 75.5 → 75 pt
//   right bezel: (5480-4508)/13.048 = 74.5 → 75 pt  (symmetric)
//   top bezel:   867/13.073  = 66.3 → 67 pt
//   bottom bezel:(4680-3821)/13.073 = 65.7 → 66 pt
private let vpTop:      CGFloat = 80
private let vpLeading:  CGFloat = 90
private let vpTrailing: CGFloat = 90
private let vpBottom:   CGFloat = 79
// Resulting viewport interior: 324 × 271 pt  (420×358 × 1.2)

/// Amber: counter digits, record button text, meter segments, labels.
private let vpAmber  = Color(red: 1.0,        green: 165/255, blue: 0)
/// Muted green border matching the counter outline in the mockup (#7FBF7F).
private let vpBorder = Color(red: 127/255,    green: 191/255, blue: 127/255)
/// Very dark warm surface — slightly warmer than pure black.
private let vpSurface = Color(red: 18/255,    green: 15/255,  blue: 10/255)

/// Phosphor green accent kept for secondary surfaces (popovers, error card borders).
private let appAccent      = Color(red: 0x39/255, green: 0xFF/255, blue: 0x14/255)
private let panelStroke    = Color(red: 0xC0/255, green: 0xC0/255, blue: 0xC0/255)
private let secondarySurface = Color(red: 0x2A/255, green: 0x2A/255, blue: 0x2A/255)
private let secondaryText    = Color(red: 0xE8/255, green: 0xE8/255, blue: 0xE8/255)
private let secondaryFieldBg = Color(red: 0x14/255, green: 0x14/255, blue: 0x14/255)

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

// Viewport interior = 324 pt wide.  14 pt inner padding each side → 296 pt.
private let vpInnerPad:     CGFloat = 14
private let vpContentWidth: CGFloat = 296   // 324 − 14 − 14

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
    /// Backing NSViews for the side buttons — captured via ViewAnchor so
    /// NSPopover can be anchored without relying on NSApp.keyWindow.
    @State private var inputAnchorView:    NSView?
    @State private var settingsAnchorView: NSView?

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

            // 3 ── Metal frame overlay (transparent cutout reveals content)
            Image("frame")
                .resizable()
                .frame(width: windowSize.width, height: windowSize.height)
                .allowsHitTesting(false)

            // 4 ── LED — blinks on the shared 0.75 s timer while recording;
            //      dark/off when idle. RECORDING label is baked into faceplate.
            Image(isRecordingState && ledFlashOn ? "led_on_2" : "led_off_2")
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .position(x: 101, y: 41)
                .allowsHitTesting(false)

            // 5 ── Input selector — nudged 5 pt toward outer frame edge so it
            //      reads as set into the faceplate rather than crowding the bezel.
            inputSelector
                .position(x: 40, y: 215)

            // 6 ── Settings — symmetric nudge toward outer frame edge.
            gearButton
                .position(x: 464, y: 215)

            // 7 ── Version overlay — sits just below the baked "DoublEnder" text
            //      in the lower-left bezel (measured: text bottom ~327 pt).
            //      x=79 pt aligns with the baked text left edge; bottom=18 pt
            //      leaves a ~13 pt gap between DoublEnder bottom and version top.
            versionOverlay
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 95)
                .padding(.bottom, 17)
                .allowsHitTesting(false)
        }
        .frame(width: windowSize.width, height: windowSize.height)
        .background(.clear)
        .onReceive(flashPublisher) { _ in
            if isRecordingState { ledFlashOn.toggle() }
            else { ledFlashOn = false }
        }
    }

    // MARK: - Viewport background

    /// Warm dark grey with subtle scanlines — sells the physical-screen illusion.
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
        }
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
        // Viewport interior: 270 × 225 pt.  vpInnerPad (12) on all sides
        // → content area 246 × 201 pt.  Elements have explicit vpContentWidth.
        VStack(spacing: 0) {
            Spacer(minLength: vpInnerPad)
            counterWindow
            warningBadge
            Spacer(minLength: 10)
            recordStopButton
            Spacer(minLength: 10)
            LevelMeter(level: viewModel.rmsLevel)
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
                .shadow(color: vpAmber.opacity(0.85), radius: 6)
            Image("counter_reflection")
                .resizable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(0.4)
                .blendMode(.screen)
                .allowsHitTesting(false)
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
                // Solid red fill while recording — no animation, no timer.
                if isRecordingState {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(red: 0.8, green: 0.0, blue: 0.0))
                }
                Text(isRecordingState ? "STOP" : "RECORD")
                    .font(panelFont(size: 41))
                    .tracking(3)
                    .foregroundColor(vpAmber)
                    .shadow(color: vpAmber.opacity(0.75), radius: 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .multilineTextAlignment(.center)
                    // Cap-only text sits optically high; nudge down to compensate
                    // for the descender whitespace the font reserves below baseline.
                    .offset(y: 6)
            }
            .frame(width: vpContentWidth, height: 72)
            .background(vpSurface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(vpBorder, lineWidth: 1.5)
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

    // MARK: - Input selector (left bezel)

    private var inputSelector: some View {
        Button {
            guard let av = inputAnchorView else { return }
            popovers.toggleInput(
                buttonView: av,
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
        } label: {
            Image(popovers.showingInput ? "input_on" : "input_off")
                .resizable()
                .scaledToFit()
                .frame(width: 62, height: 62)
                .contentShape(Rectangle())
                // Capture the button's backing NSView for popover anchoring.
                .background(ViewAnchor { inputAnchorView = $0 })
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Select input device")
    }

    // MARK: - Settings (right bezel)

    private var gearButton: some View {
        Button {
            guard let av = settingsAnchorView else { return }
            popovers.toggleSettings(
                buttonView: av,
                content: AnyView(SettingsPopover(viewModel: viewModel))
            )
        } label: {
            Image(popovers.showingSettings ? "settings_on" : "settings_off")
                .resizable()
                .scaledToFit()
                .frame(width: 62, height: 62)
                .contentShape(Rectangle())
                // Capture the button's backing NSView for popover anchoring.
                .background(ViewAnchor { settingsAnchorView = $0 })
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Settings")
    }

    // MARK: - Version overlay

    /// Dynamic version number rendered below the baked "DoublEnder" / app-name
    /// text in de_faceplate_2.png. Handel Gothic matches the faceplate's own
    /// typeface; same dark engraved colour and opacity as the former bezel label.
    private var versionOverlay: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return Text("v\(version)")
            .font(handelFont(size: 17))
            // Reduce one weight step (Regular → Light) so the version string
            // reads as subordinate to the baked app-name text above it.
            // fontWeight hints SwiftUI/CoreText to pick a lighter variant within
            // the font family; if none exists the fallback stays at Regular.
            .fontWeight(.light)
            .foregroundColor(Color(red: 0x08/255, green: 0x08/255, blue: 0x08/255))
            .shadow(color: .white.opacity(0.12), radius: 0, x: 0, y: 1)
            .opacity(0.85)
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
                    .tint(appAccent)
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
                    .foregroundStyle(appAccent)
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
                    .foregroundStyle(appAccent)
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

// MARK: - Level meter

private struct LevelMeter: View {
    let level: Float  // -60 … 0 dBFS

    private static let segCount = 40
    private static let dbMin: Float = -60
    private static let dbMax: Float =   0

    var body: some View {
        // CLIP box sits inside the same bordered container as the segment bar.
        // Total width = vpContentWidth (246); canvas takes everything left of CLIP.
        let clipW:      CGFloat = 34
        let containerH: CGFloat = 34
        let canvasW:    CGFloat = vpContentWidth - clipW   // 262 pt
        let clipping = level >= -0.1

        VStack(alignment: .leading, spacing: 4) {
            // ── Single bordered container: segment bar + CLIP ───────────
            HStack(spacing: 0) {
                Canvas { ctx, size in
                    let n = Self.segCount
                    let gap: CGFloat = 1.5
                    let inset: CGFloat = 3
                    let availW = size.width - inset * 2
                    let availH = size.height - inset * 2
                    let sw = (availW - CGFloat(n - 1) * gap) / CGFloat(n)
                    for i in 0..<n {
                        let db  = Self.dbMin + Float(i) / Float(n) * (Self.dbMax - Self.dbMin)
                        let lit = level >= db
                        // Colour zones: green ≤ −12 | amber ≤ −6 | red > −6
                        let base: Color
                        if      db < -12 { base = vpBorder }
                        else if db <  -6 { base = vpAmber  }
                        else             { base = Color(red: 0.85, green: 0.04, blue: 0.0) }
                        let c = lit ? base : base.opacity(0.15)
                        let x = inset + CGFloat(i) * (sw + gap)
                        let rect = CGRect(x: x, y: inset, width: max(sw, 1), height: availH)
                        ctx.fill(RoundedRectangle(cornerRadius: 1).path(in: rect), with: .color(c))
                    }
                }
                .frame(width: canvasW, height: containerH)

                // CLIP indicator — shares the outer border; its background
                // flips to red when the signal hits 0 dBFS.
                Text("CLIP")
                    .font(.system(size: 7, weight: .bold))
                    .tracking(0.4)
                    .foregroundColor(clipping ? .white : vpAmber.opacity(0.22))
                    .frame(width: clipW, height: containerH)
                    .background(clipping
                        ? Color(red: 0.8, green: 0, blue: 0)
                        : vpSurface)
            }
            .frame(width: vpContentWidth, height: containerH)
            .background(vpSurface)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(vpBorder, lineWidth: 1.2))

            // ── dBFS scale labels ───────────────────────────────────────
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
            .frame(height: 12)
        }
        .frame(width: vpContentWidth)
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
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(appAccent, lineWidth: 1))
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
                        .foregroundColor(appAccent)
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
                    TextField("DoublEnder", text: $viewModel.filenameBase)
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
                .tint(appAccent)
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
