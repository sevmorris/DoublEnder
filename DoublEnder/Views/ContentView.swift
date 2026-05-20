import SwiftUI
import AVFoundation
import AppKit

// MARK: - Design tokens

/// New window size — matches frame.png aspect ratio (5480 : 4680 ≈ 1.17 : 1).
private let windowSize = CGSize(width: 420, height: 358)

/// Viewport insets — the area revealed by the frame.png cutout.
private let vpTop:      CGFloat = 38
private let vpLeading:  CGFloat = 58
private let vpTrailing: CGFloat = 58
private let vpBottom:   CGFloat = 52

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

private let crtFontCandidates: [String] = [
    "EurostileLTStd-Bold", "Eurostile-Bold", "Eurostile",
    "BankGothicBT-Medium", "BankGothic-Medium", "Bank Gothic",
    "DSEG7Classic-Regular"
]

private func crtFont(size: CGFloat) -> Font {
    for name in crtFontCandidates where NSFont(name: name, size: size) != nil {
        return .custom(name, size: size)
    }
    return .system(size: size, weight: .bold, design: .monospaced)
}

// MARK: - ContentView

struct ContentView: View {
    @ObservedObject private var viewModel = RecorderViewModel.shared
    @State private var isStopping    = false
    @State private var showDevicePicker = false
    @State private var showSettings  = false
    /// Drives the LED blink and RECORD-button red pulse in perfect sync.
    @State private var ledFlashOn    = false

    /// Single shared publisher — LED image and record-button fill both read
    /// this flag so they are always in phase (spec §5).
    private let flashPublisher = Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // 1 ── Viewport background (behind frame cutout)
            viewportBackground

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

            // 4 ── LED indicator, positioned in top-left bezel
            Image(isRecordingState && ledFlashOn ? "led_on" : "led_off")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .position(x: 52, y: 44)
                .allowsHitTesting(false)

            // 5 ── Input selector — left bezel
            inputSelector
                .position(x: 29, y: 207)

            // 6 ── Settings — right bezel
            gearButton
                .position(x: 391, y: 207)
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
        VStack(spacing: 0) {
            Spacer().frame(height: 14)
            counterWindow
            warningBadge
            Spacer().frame(height: 12)
            recordStopButton
            Spacer().frame(height: 10)
            LevelMeter(level: viewModel.rmsLevel)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Counter window

    private var counterWindow: some View {
        ZStack {
            vpSurface
            Text(viewModel.recordingTime.hhmmss)
                .font(crtFont(size: 30))
                .tracking(2)
                .foregroundColor(vpAmber)
                .shadow(color: vpAmber.opacity(0.85), radius: 5)
            Image("counter_reflection")
                .resizable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(0.4)
                .blendMode(.screen)
                .allowsHitTesting(false)
        }
        .frame(width: 248, height: 56)
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
                // Red fill pulses in sync with the LED when recording.
                if isRecordingState && ledFlashOn {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(red: 0.8, green: 0.0, blue: 0.0))
                }
                Text(isRecordingState ? "STOP" : "RECORD")
                    .font(crtFont(size: 17))
                    .tracking(3)
                    .foregroundColor(vpAmber)
                    .shadow(color: vpAmber.opacity(0.75), radius: 4)
            }
            .frame(width: 248, height: 42)
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
        Button { showDevicePicker.toggle() } label: {
            Image("input_button")
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isRecordingState)
        .help(isRecordingState ? "Input unavailable while recording" : "Select input device")
        .popover(isPresented: $showDevicePicker, arrowEdge: .trailing) {
            DevicePickerPopover(
                microphones: viewModel.inputDeviceGroups.microphones,
                virtualDevices: viewModel.inputDeviceGroups.virtual,
                selectedID: viewModel.selectedInputDeviceID,
                onSelect: { id in
                    viewModel.selectedInputDeviceID = id
                    showDevicePicker = false
                }
            )
        }
    }

    // MARK: - Settings (right bezel)

    private var gearButton: some View {
        Button { showSettings.toggle() } label: {
            Image("settings_button")
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isRecordingState)
        .help(isRecordingState ? "Settings unavailable while recording" : "Settings")
        .popover(isPresented: $showSettings, arrowEdge: .leading) {
            SettingsPopover(viewModel: viewModel)
        }
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

    private let amber  = vpAmber
    private let border = vpBorder
    private let bg     = vpSurface

    private func segColor(index: Int) -> Color {
        let db  = Self.dbMin + Float(index) / Float(Self.segCount) * (Self.dbMax - Self.dbMin)
        let lit = level >= db
        let base: Color
        if      db < -12 { base = amber }
        else if db <  -6 { base = Color(red: 1.0, green: 0.72, blue: 0.0) }
        else if db <  -3 { base = Color(red: 1.0, green: 0.30, blue: 0.0) }
        else             { base = Color(red: 0.85, green: 0.04, blue: 0.0) }
        return lit ? base : base.opacity(0.14)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ── Segment bar + CLIP ──────────────────────────────────────
            HStack(spacing: 4) {
                // 40 segments drawn with Canvas for precise sizing.
                Canvas { ctx, size in
                    let n   = Self.segCount
                    let gap: CGFloat = 1.5
                    let inset: CGFloat = 3
                    let availW = size.width - inset * 2
                    let availH = size.height - inset * 2
                    let sw = (availW - CGFloat(n - 1) * gap) / CGFloat(n)
                    for i in 0..<n {
                        let db  = Self.dbMin + Float(i) / Float(n) * (Self.dbMax - Self.dbMin)
                        let lit = level >= db
                        let base: Color
                        if      db < -12 { base = vpAmber }
                        else if db <  -6 { base = Color(red: 1.0, green: 0.72, blue: 0.0) }
                        else if db <  -3 { base = Color(red: 1.0, green: 0.30, blue: 0.0) }
                        else             { base = Color(red: 0.85, green: 0.04, blue: 0.0) }
                        let c = lit ? base : base.opacity(0.14)
                        let x = inset + CGFloat(i) * (sw + gap)
                        let rect = CGRect(x: x, y: inset, width: max(sw, 1), height: availH)
                        ctx.fill(RoundedRectangle(cornerRadius: 1).path(in: rect), with: .color(c))
                    }
                }
                .frame(height: 22)
                .background(bg)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(border, lineWidth: 1.2))

                // CLIP indicator
                let clipping = level >= -0.1
                Text("CLIP")
                    .font(.system(size: 7, weight: .bold))
                    .tracking(0.4)
                    .foregroundColor(clipping ? .white : amber.opacity(0.22))
                    .frame(width: 28, height: 28)
                    .background(clipping ? Color(red: 0.8, green: 0, blue: 0) : bg)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(border, lineWidth: 1.2))
            }

            // ── dBFS scale labels ───────────────────────────────────────
            GeometryReader { geo in
                // Subtract CLIP box width + gap to align labels with segment area only.
                let clipOffset: CGFloat = 28 + 4
                let segW = geo.size.width - clipOffset
                let labels: [(Float, String)] = [
                    (-60, "-60"), (-48, "-48"), (-36, "-36"),
                    (-24, "-24"), (-12, "-12"), (-6, "-6"), (0, "0")
                ]
                ForEach(0..<labels.count, id: \.self) { i in
                    let (db, text) = labels[i]
                    let frac = CGFloat((db - Self.dbMin) / (Self.dbMax - Self.dbMin))
                    Text(text)
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundColor(amber.opacity(0.55))
                        .position(x: frac * segW, y: 5)
                }
            }
            .frame(height: 12)
        }
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
                    .strokeBorder(appAccent, lineWidth: 1.5)
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
                sectionHeader("MICROPHONES", topPadding: 10)
                ForEach(microphones, id: \.uniqueID) { row($0, dimmed: false) }
            }
            if !virtualDevices.isEmpty {
                sectionHeader("VIRTUAL & AGGREGATE", topPadding: microphones.isEmpty ? 10 : 12)
                ForEach(virtualDevices, id: \.uniqueID) { row($0, dimmed: true) }
            }
        }
        .padding(.bottom, 6)
        .frame(minWidth: 220)
        .background(secondarySurface)
        .preferredColorScheme(.dark)
    }

    private func sectionHeader(_ text: String, topPadding: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(1.5)
            .foregroundColor(appAccent)
            .padding(.horizontal, 12)
            .padding(.top, topPadding)
            .padding(.bottom, 4)
    }

    private func row(_ device: AVCaptureDevice, dimmed: Bool) -> some View {
        Button { onSelect(device.uniqueID) } label: {
            HStack {
                Text(device.localizedName)
                    .font(.system(size: 11))
                    .foregroundColor(secondaryText.opacity(dimmed ? 0.45 : 1.0))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if selectedID == device.uniqueID {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(appAccent)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

// MARK: - Settings popover

private struct SettingsPopover: View {
    @ObservedObject var viewModel: RecorderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SETTINGS")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.8)
                .foregroundColor(appAccent)

            // Filename
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("FILENAME")
                HStack(spacing: 6) {
                    TextField("DoublEnder", text: $viewModel.filenameBase)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(secondaryFieldBg)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(panelStroke, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text("_<date>.\(viewModel.outputFormat.fileExtension)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(secondaryText.opacity(0.55))
                        .fixedSize()
                }
            }

            // Notes
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("NOTES")
                ZStack(alignment: .topLeading) {
                    if viewModel.notes.isEmpty {
                        Text("Saved as metadata in the recording")
                            .font(.system(size: 10))
                            .italic()
                            .foregroundColor(secondaryText.opacity(0.45))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $viewModel.notes)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 11))
                        .foregroundColor(secondaryText)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                }
                .frame(height: 56)
                .background(secondaryFieldBg)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(panelStroke, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                if viewModel.outputFormat == .wav {
                    Text("Notes are not stored in WAV files.")
                        .font(.system(size: 9))
                        .foregroundColor(secondaryText.opacity(0.55))
                }
            }

            // Format
            VStack(alignment: .leading, spacing: 4) {
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
                     ? "Recorded as mono, 256 kbps. For multi-channel or >96 kHz sources, use WAV."
                     : "Recorded as mono at the hardware sample rate (uncompressed).")
                    .font(.system(size: 9))
                    .foregroundColor(secondaryText.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 260)
        .background(secondarySurface)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(1.2)
            .foregroundColor(appAccent)
    }
}
