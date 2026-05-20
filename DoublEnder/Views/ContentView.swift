import SwiftUI
import AVFoundation
import AppKit

// Accent for secondary surfaces — kept on the same phosphor green as the
// counter digits so light text, borders, and buttons read as part of one
// visual family. (Name preserved to keep this diff small.)
private let accentBlue = Color(red: 0x39/255, green: 0xFF/255, blue: 0x14/255)
private let panelStroke = Color(red: 0xC0/255, green: 0xC0/255, blue: 0xC0/255)
// Dark neutral surface for popovers and secondary windows. Background is a
// deep grey with near-white primary text, tied to the main panel by the
// accent-blue border / button outline.
private let secondarySurface = Color(red: 0x2A/255, green: 0x2A/255, blue: 0x2A/255)
private let secondaryText    = Color(red: 0xE8/255, green: 0xE8/255, blue: 0xE8/255)
private let secondaryFieldBg = Color(red: 0x14/255, green: 0x14/255, blue: 0x14/255)
private let windowSize = CGSize(width: 320, height: 338)
private let grillBandHeight: CGFloat = 93


// CRT-style timer readout: phosphor green digits in a clean wide sans-serif.
// Eurostile/Bank Gothic ship with some pro design suites but not stock macOS,
// so the helper walks a preferred-name list and falls back to SF Mono Bold
// if none are installed.
private let phosphorGreen = Color(red: 0x39/255, green: 0xFF/255, blue: 0x14/255)
private let crtFontCandidates: [String] = [
    "EurostileLTStd-Bold", "Eurostile-Bold", "Eurostile",
    "BankGothicBT-Medium", "BankGothic-Medium", "Bank Gothic"
]

private func crtFont(size: CGFloat) -> Font {
    for name in crtFontCandidates where NSFont(name: name, size: size) != nil {
        return .custom(name, size: size)
    }
    return .system(size: size, weight: .bold, design: .monospaced)
}

struct ContentView: View {
    // Singleton — AppDelegate also references this for quit-intercept and
    // crash-recovery checks, and the view simply observes its state.
    @ObservedObject private var viewModel = RecorderViewModel.shared
    @State private var isStopping = false            // true while finishWriting is in flight; blocks double-tap
    @State private var showDevicePicker = false
    @State private var showSettings = false

    // Phosphor-green CRT readout sits in a pure-black counter box.
    private let lcdBackground = Color.black

    var body: some View {
        ZStack {
            backgroundChrome
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: windowSize.width, height: windowSize.height)
        .background(.clear)
    }

    // Hard-edged rectangle: full black panel with a grill band at the bottom
    // and a single silver hairline border. The grill runs straight into all
    // four corners — no clip shape to truncate it. A soft radial vignette
    // sits on top of the panel to nudge the eye toward the lens at centre.
    private var backgroundChrome: some View {
        ZStack(alignment: .bottom) {
            Color.black
            Image("grill")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: grillBandHeight)
                .frame(maxWidth: .infinity)
                .clipped()
        }
        .overlay(
            RadialGradient(
                colors: [.clear, Color.black.opacity(0.3)],
                center: .center,
                startRadius: 70,
                endRadius: 230
            )
            .allowsHitTesting(false)
        )
        .overlay(
            Rectangle()
                .strokeBorder(panelStroke, lineWidth: 1.5)
        )
    }

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
            Spacer().frame(height: 16)
            counterWindow
            Spacer().frame(height: 8)
            middleRow
            // Flexible — the bottom of the window is pure grill now that the
            // meter is gone, so let the spacer absorb whatever room is left.
            Spacer(minLength: 8)
        }
    }

    // MARK: - Counter window (top)

    private var counterWindow: some View {
        ZStack {
            // 1. Black LCD background.
            lcdBackground

            // 2. Phosphor-green digits with CRT glow.
            Text(viewModel.recordingTime.hhmmss)
                .font(crtFont(size: 30))
                .tracking(2)
                .foregroundColor(phosphorGreen)
                .shadow(color: phosphorGreen.opacity(0.85), radius: 5)

            // 3. Glossy curved highlight on top. `.screen` at 0.4 lifts the
            //    reflection over the dark background without flattening the
            //    bright green digits the way `.overlay` did.
            Image("counter_reflection")
                .resizable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(0.4)
                .blendMode(.screen)
                .allowsHitTesting(false)
        }
        .frame(width: 248, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(panelStroke, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
    }

    // MARK: - Middle row (mic selector + record button + gear)

    private var middleRow: some View {
        ZStack {
            recordButton
            HStack {
                inputSelector
                Spacer(minLength: 0)
                gearButton
            }
            // Visually the record button's lit centre sits a little above
            // the geometric midpoint of the 135pt image, so nudge the
            // flanking icons up to read as truly aligned with the lens.
            .offset(y: -6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 135)
    }

    private var inputSelector: some View {
        Button {
            showDevicePicker.toggle()
        } label: {
            Image("mic")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
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

    // MARK: - Gear / settings

    private var gearButton: some View {
        Button {
            showSettings.toggle()
        } label: {
            Image("gear")
                .resizable()
                .scaledToFit()
                .frame(width: 31, height: 31)
                .contentShape(Rectangle())
                .padding(.trailing, 10)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isRecordingState)
        .help(isRecordingState ? "Settings unavailable while recording" : "Settings")
        .popover(isPresented: $showSettings, arrowEdge: .top) {
            SettingsPopover(viewModel: viewModel)
        }
    }

    // MARK: - Record button

    private var isRecordingState: Bool {
        if case .recording = viewModel.state { return true }
        return false
    }

    // Both record_button_on / record_button_off render at the same size
    // and crossfade by opacity while recording. Nothing wraps them — no
    // ring, no border, just the image itself.
    private static let recordButtonSize: CGFloat = 135

    private var recordButton: some View {
        Group {
            if isRecordingState {
                // Crossfade between the two states while recording. View is
                // conditionally mounted so SwiftUI tears down the repeating
                // animation the instant recording stops — no timers, no
                // animation cancellation to chase.
                RecordCrossfade(size: Self.recordButtonSize)
            } else {
                Image("record_button_off")
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.recordButtonSize, height: Self.recordButtonSize)
            }
        }
        .frame(width: Self.recordButtonSize, height: Self.recordButtonSize)
        .contentShape(Circle())
        .onTapGesture { handleRecordTap() }
    }

    private func handleRecordTap() {
        switch viewModel.state {
        case .recording:
            guard !isStopping else { return }
            isStopping = true
            viewModel.stopRecording {
                isStopping = false
            }
        case .selectingMic, .ready:
            viewModel.startRecording()
        default:
            break
        }
    }

    // MARK: - Other state views

    #if GCS_ENABLED
    private var uploadingView: some View {
        SecondaryCard {
            VStack(spacing: 12) {
                Text("Uploading…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(secondaryText)
                ProgressView(value: viewModel.uploadProgress)
                    .progressViewStyle(.linear)
                    .tint(accentBlue)
                    .frame(width: 168)
                Text("\(Int(viewModel.uploadProgress * 100))%")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(secondaryText)
                    .monospacedDigit()
            }
        }
    }

    /// Upload failed after automatic retries. The recording is safe on the
    /// Desktop — only the upload needs retrying, so this is visually the
    /// error view but reassures the user and re-attempts just the upload.
    private func uploadFailedView(_ url: URL) -> some View {
        SecondaryCard {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.icloud.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(accentBlue)

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
                    .foregroundStyle(accentBlue)

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

// MARK: - Secondary surface components

/// Light-grey rounded card used for every non-primary surface (popovers,
/// in-window dialogs). Mirrors the silver-stroke aesthetic of the main
/// window with an accent-blue border instead of silver, so secondary UI
/// reads as related-but-distinct from the dark recording panel.
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
                    .strokeBorder(accentBlue, lineWidth: 1.5)
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
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(accentBlue, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

// MARK: - Record-button recording crossfade

/// Smoothly crossfades between record_button_off and record_button_on while
/// recording. Lives only as long as it's mounted — when the parent stops
/// including it in the hierarchy, SwiftUI tears it down and the repeating
/// animation goes with it. No timers, no animation cancellation to manage.
private struct RecordCrossfade: View {
    let size: CGFloat
    @State private var onOpacity: Double = 0.0

    var body: some View {
        ZStack {
            Image("record_button_off")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
            Image("record_button_on")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .opacity(onOpacity)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                onOpacity = 1.0
            }
        }
    }
}

// MARK: - Device Picker Popover

private struct DevicePickerPopover: View {
    let microphones: [AVCaptureDevice]
    let virtualDevices: [AVCaptureDevice]
    let selectedID: String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !microphones.isEmpty {
                sectionHeader("MICROPHONES", topPadding: 10)
                ForEach(microphones, id: \.uniqueID) { row($0, dimmed: false) }
            }

            if !virtualDevices.isEmpty {
                sectionHeader(
                    "VIRTUAL & AGGREGATE",
                    topPadding: microphones.isEmpty ? 10 : 12
                )
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
            .foregroundColor(accentBlue)
            .padding(.horizontal, 12)
            .padding(.top, topPadding)
            .padding(.bottom, 4)
    }

    private func row(_ device: AVCaptureDevice, dimmed: Bool) -> some View {
        Button {
            onSelect(device.uniqueID)
        } label: {
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
                        .foregroundColor(accentBlue)
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

// MARK: - Settings Popover

private struct SettingsPopover: View {
    @ObservedObject var viewModel: RecorderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SETTINGS")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.8)
                .foregroundColor(accentBlue)

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
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(panelStroke, lineWidth: 1)
                        )
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
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(panelStroke, lineWidth: 1)
                )
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
                .tint(accentBlue)
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
            .foregroundColor(accentBlue)
    }
}
