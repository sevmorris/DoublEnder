import SwiftUI
import AVFoundation
import AppKit

// MARK: - Viewport shell

/// Near-black warm surface with scanlines and radial vignette.
struct FaceplateViewportBackground: View {
    var body: some View {
        ZStack {
            FaceplateDesign.vpSurface
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
}

/// Amber screen glow — warm light spills from cutout onto inner bezel.
struct FaceplateScreenGlow: View {
    var body: some View {
        Rectangle()
            .fill(FaceplateDesign.screenGlowColor.opacity(0.04))
            .padding(FaceplateDesign.viewportInsets)
            .shadow(color: FaceplateDesign.screenGlowColor.opacity(0.40), radius: 18)
            .allowsHitTesting(false)
    }
}

// MARK: - NSPopover manager

/// Owns both NSPopovers so they float outside the borderless window.
/// Transient — dismissed automatically when the user clicks elsewhere.
@MainActor
final class FaceplatePopoverManager: NSObject, ObservableObject, NSPopoverDelegate {
    @Published private(set) var showingInput    = false
    @Published private(set) var showingSettings = false

    private var inputPop:    NSPopover?
    private var settingsPop: NSPopover?
    /// The app window that owns the anchor buttons. Captured when a popover
    /// opens so popoverDidClose can re-activate it without relying on
    /// NSApp.keyWindow, which may still reference the closing popover panel.
    private weak var anchoredWindow: NSWindow?

    /// Opens the input-device popover to the LEFT of the app window.
    func toggleInput(buttonView: NSView, content: AnyView) {
        if inputPop != nil { closeInput(); return }
        settingsPop?.close()
        guard let window = buttonView.window,
              let windowView = window.contentView else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        anchoredWindow = window
        let btnInWindow = buttonView.convert(buttonView.bounds, to: windowView)
        let anchor = NSRect(x: 0, y: btnInWindow.minY, width: 0, height: btnInWindow.height)
        let p = makePop(content)
        p.show(relativeTo: anchor, of: windowView, preferredEdge: .minX)
        inputPop = p; showingInput = true
    }

    /// Opens the settings popover to the RIGHT of the app window.
    func toggleSettings(buttonView: NSView, content: AnyView) {
        if settingsPop != nil { closeSettings(); return }
        inputPop?.close()
        guard let window = buttonView.window,
              let windowView = window.contentView else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        anchoredWindow = window
        let btnInWindow = buttonView.convert(buttonView.bounds, to: windowView)
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
        anchoredWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Meter row

/// Three independent controls: input button, level meter, settings button.
struct FaceplateMeterRow: View {
    let level: Float
    let inputActive: Bool
    let settingsActive: Bool
    var inputDisabled: Bool = false
    var settingsDisabled: Bool = false
    var onInputTap:    (NSView) -> Void
    var onSettingsTap: (NSView) -> Void

    @State private var inputAnchor:    NSView?
    @State private var settingsAnchor: NSView?

    private static let segCount = LevelMeter.segmentCount
    private static let dbMin: Float = LevelMeter.dbFloor
    private static let dbMax: Float = LevelMeter.dbCeiling

    var body: some View {
        let containerH: CGFloat = 34
        let iconBoxW:   CGFloat = 34
        let gap:        CGFloat = 6
        let meterW:     CGFloat = FaceplateDesign.vpContentWidth - (iconBoxW * 2) - (gap * 2)

        HStack(alignment: .top, spacing: gap) {
            iconButton(
                name: "input_icon",
                active: inputActive,
                width: iconBoxW, height: containerH,
                help: inputDisabled ? "Stop recording to change input" : "Select input device",
                disabled: inputDisabled,
                capture: { inputAnchor = $0 },
                onTap: { if let av = inputAnchor { onInputTap(av) } }
            )
            meterUnit(meterW: meterW, containerH: containerH)
            iconButton(
                name: "settings_icon",
                active: settingsActive,
                width: iconBoxW, height: containerH,
                help: settingsDisabled ? "Stop recording to change settings" : "Settings",
                disabled: settingsDisabled,
                capture: { settingsAnchor = $0 },
                onTap: { if let av = settingsAnchor { onSettingsTap(av) } }
            )
        }
        .frame(width: FaceplateDesign.vpContentWidth)
    }

    @ViewBuilder
    private func meterUnit(
        meterW: CGFloat,
        containerH: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { ctx, size in
                let n = Self.segCount
                let segGap: CGFloat = 1.5
                let inset:  CGFloat = 3
                let availW = size.width - inset * 2
                let availH = size.height - inset * 2
                let sw = (availW - CGFloat(n - 1) * segGap) / CGFloat(n)
                // 1 dB deadzone above the floor: real ambient noise dwells
                // just above dbMin after clamping, so without this the
                // leftmost segment stays lit at idle and the meter reads
                // as frozen rather than quiet.
                let aboveDeadzone = level > Self.dbMin + 1.0
                for i in 0..<n {
                    let db  = Self.dbMin + Float(i) / Float(n) * (Self.dbMax - Self.dbMin)
                    let lit = aboveDeadzone && level >= db
                    let base: Color
                    if      db < -18 { base = FaceplateDesign.meterSafe    }
                    else if db <  -6 { base = FaceplateDesign.meterWarning }
                    else             { base = FaceplateDesign.meterDanger   }
                    let c = lit ? base : FaceplateDesign.meterInactive
                    let x = inset + CGFloat(i) * (sw + segGap)
                    let rect = CGRect(x: x, y: inset, width: max(sw, 1), height: availH)
                    ctx.fill(RoundedRectangle(cornerRadius: 1).path(in: rect), with: .color(c))
                }
            }
            .frame(width: meterW, height: containerH)
            .background(FaceplateDesign.vpSurface)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(FaceplateDesign.vpBorder, lineWidth: 1.2))

            GeometryReader { _ in
                let labels = LevelMeter.scaleLabels
                ForEach(0..<labels.count, id: \.self) { i in
                    let (db, text) = labels[i]
                    let frac = CGFloat((db - Self.dbMin) / (Self.dbMax - Self.dbMin))
                    Text(text)
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundColor(FaceplateDesign.vpAmber.opacity(0.55))
                        .position(x: frac * meterW, y: 5)
                }
            }
            .frame(width: meterW, height: 12)
        }
    }

    @ViewBuilder
    private func iconButton(
        name: String,
        active: Bool,
        width: CGFloat,
        height: CGFloat,
        help: String,
        disabled: Bool = false,
        capture: @escaping (NSView) -> Void,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            Image(name)
                .resizable()
                .scaledToFit()
                .foregroundColor(FaceplateDesign.vpAmber.opacity(disabled ? 0.35 : (active ? 1.0 : 0.65)))
                .frame(width: 20, height: 20)
                .frame(width: width, height: height, alignment: .center)
                .background(FaceplateDesign.vpSurface)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(FaceplateDesign.vpBorder, lineWidth: 1.2))
                .contentShape(Rectangle())
                .background(ViewAnchor { capture($0) })
        }
        .buttonStyle(.plain)
        .focusEffectDisabledIfAvailable()
        .disabled(disabled)
        .help(help)
    }
}

// MARK: - NSView capture helper

struct ViewAnchor: NSViewRepresentable {
    let onCapture: (NSView) -> Void

    func makeNSView(context: Context) -> AnchorView {
        let v = AnchorView()
        v.onCapture = onCapture
        return v
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.onCapture = onCapture
    }

    final class AnchorView: NSView {
        var onCapture: ((NSView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onCapture?(self) }
        }

        override var mouseDownCanMoveWindow: Bool { false }
    }
}

// MARK: - Secondary surface components

struct FaceplateSecondaryCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FaceplateDesign.secondarySurface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(FaceplateDesign.vpBorder, lineWidth: 1.5)
            )
            .preferredColorScheme(.dark)
    }
}

struct FaceplateSecondaryButton: View {
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
                .foregroundColor(FaceplateDesign.secondaryText)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 4).fill(FaceplateDesign.secondaryFieldBg))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(FaceplateDesign.vpAmber, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusEffectDisabledIfAvailable()
    }
}

// MARK: - Device picker popover

struct FaceplateDevicePickerPopover: View {
    let microphones: [AVCaptureDevice]
    let selectedID:  String
    let onSelect:    (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !microphones.isEmpty {
                sectionHeader("MICROPHONES", topPadding: 12)
                ForEach(microphones, id: \.uniqueID) { row($0) }
            }
        }
        .padding(.bottom, 8)
        .frame(minWidth: 275)
        .background(FaceplateDesign.secondarySurface)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(FaceplateDesign.vpBorder, lineWidth: 1.5))
        .preferredColorScheme(.dark)
    }

    private func sectionHeader(_ text: String, topPadding: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(1.5)
            .foregroundColor(FaceplateDesign.vpAmber)
            .padding(.horizontal, 15)
            .padding(.top, topPadding)
            .padding(.bottom, 5)
    }

    private func row(_ device: AVCaptureDevice) -> some View {
        Button { onSelect(device.uniqueID) } label: {
            HStack {
                Text(device.localizedName)
                    .font(.system(size: 14))
                    .foregroundColor(FaceplateDesign.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if selectedID == device.uniqueID {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(FaceplateDesign.vpAmber)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .focusEffectDisabledIfAvailable()
    }
}

// MARK: - Settings popover

struct FaceplateSettingsPopover: View {
    @ObservedObject var viewModel: RecorderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("SETTINGS")
                .font(.system(size: 13, weight: .bold))
                .tracking(1.8)
                .foregroundColor(FaceplateDesign.vpAmber)

            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("FILENAME")
                HStack(spacing: 8) {
                    TextField(RecorderViewModel.defaultRecordingPrefix, text: $viewModel.filenameBase)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundColor(FaceplateDesign.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(FaceplateDesign.secondaryFieldBg)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(FaceplateDesign.panelStroke, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text("_<date>.\(viewModel.outputFormat.fileExtension)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(FaceplateDesign.secondaryText.opacity(0.55))
                        .fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("NOTES")
                ZStack(alignment: .topLeading) {
                    if viewModel.notes.isEmpty {
                        Text("Saved as metadata in the recording")
                            .font(.system(size: 12))
                            .italic()
                            .foregroundColor(FaceplateDesign.secondaryText.opacity(0.45))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $viewModel.notes)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 14))
                        .foregroundColor(FaceplateDesign.secondaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 4)
                }
                .frame(height: 70)
                .background(FaceplateDesign.secondaryFieldBg)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(FaceplateDesign.panelStroke, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                if viewModel.outputFormat == .wav {
                    Text("Notes are not stored in WAV files.")
                        .font(.system(size: 11))
                        .foregroundColor(FaceplateDesign.secondaryText.opacity(0.55))
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("FORMAT")
                Picker("", selection: $viewModel.outputFormat) {
                    ForEach(OutputFormat.allCases) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(FaceplateDesign.vpAmber)
                Text(viewModel.outputFormat == .aac
                     ? "Recorded as mono, 256 kbps. Smaller file size, transparent quality for voice."
                     : "Uncompressed 24-bit PCM at the hardware's native sample rate. Professional quality, universally compatible.")
                    .font(.system(size: 11))
                    .foregroundColor(FaceplateDesign.secondaryText.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            #if GCS_ENABLED
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("CLOUD")
                Toggle("Upload recordings to the cloud", isOn: $viewModel.cloudUploadEnabled)
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                    .foregroundColor(FaceplateDesign.secondaryText)
                    .tint(FaceplateDesign.recordAccent)
                    // Changing modes mid-take or mid-transfer would strand the
                    // in-flight take; the take must land first.
                    .disabled(viewModel.isCurrentlyRecording || viewModel.isCurrentlyUploading)
                Text(viewModel.cloudUploadEnabled
                     ? "Recordings upload automatically and the session appears on the producer's dashboard."
                     : "Local only — recordings save to the Desktop and are never uploaded. Nothing appears on the dashboard.")
                    .font(.system(size: 11))
                    .foregroundColor(FaceplateDesign.secondaryText.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif
        }
        .padding(20)
        .frame(width: 325)
        .background(FaceplateDesign.secondarySurface)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(FaceplateDesign.vpBorder, lineWidth: 1.5))
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(1.2)
            .foregroundColor(FaceplateDesign.vpAmber)
    }
}
