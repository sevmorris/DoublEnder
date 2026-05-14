import SwiftUI
import AVFoundation

private let panelBlue = Color(red: 0.13, green: 0.34, blue: 0.58)
private let panelBlueDark = Color(red: 0.09, green: 0.22, blue: 0.38)   // popover background — deeper than the main panel
private let panelOrange = Color(red: 0.93, green: 0.56, blue: 0.22)
private let counterBorder = Color(white: 0.42)
private let windowSize = CGSize(width: 288, height: 276)
private let counterFontName = "DSEG7Classic-Regular"

struct ContentView: View {
    // Singleton — AppDelegate also references this for quit-intercept and
    // crash-recovery checks, and the view simply observes its state.
    @ObservedObject private var viewModel = RecorderViewModel.shared
    @State private var showLit: Bool = false         // when true render record-button-on; flipped by pulseTimer
    @State private var pulseTimer: Timer?            // 1 s repeating timer; nil when not recording
    @State private var showDevicePicker = false
    @State private var showSettings = false

    // LCD readout colors — dark warm bezel with dim ghost segments and lit amber digits.
    private let lcdBackground = Color(red: 0.13, green: 0.07, blue: 0.02)
    private let lcdGhost     = Color(red: 0.93, green: 0.56, blue: 0.22).opacity(0.10)

    var body: some View {
        ZStack {
            backgroundChrome
            content
                .padding(.horizontal, 17)
                .padding(.vertical, 14)
        }
        .frame(width: windowSize.width, height: windowSize.height)
        .background(.clear)   // window is transparent — desktop shows outside the rounded rect
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var backgroundChrome: some View {
        RoundedRectangle(cornerRadius: 17, style: .continuous)
            .fill(panelBlue)
            .overlay(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(panelOrange, lineWidth: 2.5)   // strokeBorder keeps the line inside the path so clipShape doesn't clip it
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
        #endif
        case .error(let message):
            errorView(message)
        }
    }

    // MARK: - Main layout

    private var mainView: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 10)
            counterWindow
            Spacer(minLength: 7)
            middleRow
            Spacer().frame(height: 8)
            meter
            Spacer().frame(height: 6)
        }
    }

    // MARK: - Counter window (top)

    private var counterWindow: some View {
        ZStack {
            // Ghost layer — every segment lit, dim. With DSEG7, "8" lights all 7 segments,
            // so rendering "88:88:88" beneath the live readout exposes the unlit segments
            // through the active digits and sells the physical LCD look.
            Text("88:88:88")
                .font(.custom(counterFontName, size: 28))
                .tracking(1)
                .foregroundColor(lcdGhost)
            // Active digits — bright amber with two-stop glow.
            Text(viewModel.recordingTime.hhmmss)
                .font(.custom(counterFontName, size: 28))
                .tracking(1)
                .foregroundColor(panelOrange)
                .shadow(color: panelOrange.opacity(0.75), radius: 3)
                .shadow(color: panelOrange.opacity(0.45), radius: 7)
        }
        .padding(.horizontal, 18)
        .frame(height: 49)
        .background(lcdBackground)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(counterBorder, lineWidth: 1))
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
        }
        .frame(maxWidth: .infinity)
        .frame(height: 132)
    }

    private var inputSelector: some View {
        Button {
            showDevicePicker.toggle()
        } label: {
            HStack(spacing: -12) {
                Image("mic")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 43, height: 43)
                Image("input_selector")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 14)
            }
            .frame(height: 43)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .popover(isPresented: $showDevicePicker, arrowEdge: .trailing) {
            DevicePickerPopover(
                devices: viewModel.availableInputDevices,
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
                .frame(width: 28, height: 28)
                .opacity(isRecordingState ? 0.35 : 1.0)
                .contentShape(Rectangle())
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

    private var recordButton: some View {
        Image(showLit ? "record-button-on" : "record-button-off")
            .resizable()
            .scaledToFit()
            .frame(width: 112, height: 112)   // 132 × 0.85
            .contentShape(Circle())
            .onTapGesture { handleRecordTap() }
            .onAppear {
                // Defensive: no flash logic should be running until the user taps record.
                stopPulseTimer()
                showLit = false
            }
            .onChange(of: isRecordingState) { _, recording in
                updatePulse(recording: recording)
            }
            .onDisappear { stopPulseTimer() }
    }

    private func handleRecordTap() {
        switch viewModel.state {
        case .recording:
            viewModel.stopRecording()
        case .selectingMic, .ready:
            viewModel.startRecording()
        default:
            break
        }
    }

    private func updatePulse(recording: Bool) {
        stopPulseTimer()
        if recording {
            // Hard flash — 2 toggles/sec → on for 0.5 s, off for 0.5 s.
            showLit = true
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                showLit.toggle()
            }
        } else {
            // Snap back to off — no animation.
            showLit = false
        }
    }

    private func stopPulseTimer() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    // MARK: - Meter (bottom)

    private let meterTicks: [(db: Float, label: String)] = [
        (-60, "-60"), (-40, "-40"), (-20, "-20"), (-12, "-12"), (-6, "-6"), (-3, "-3"), (0, "0")
    ]

    // Segmented LED meter — 40 segments split into four colored zones.
    // Green:  -60..-12 dBFS  (positions 0.00..0.90 → 32 segments)
    // Yellow: -12..-6  dBFS  (positions 0.80..0.90 →  4 segments)
    // Orange: -6..-3   dBFS  (positions 0.90..0.95 →  2 segments)
    // Red:    -3..0    dBFS  (positions 0.95..1.00 →  2 segments)
    private static let segmentCount = 40
    private static let segmentSpacing: CGFloat = 1
    private static let zoneGreen  = Color(red: 0.18, green: 0.85, blue: 0.30)
    private static let zoneYellow = Color(red: 0.95, green: 0.82, blue: 0.20)
    private static let zoneOrange = Color(red: 0.96, green: 0.55, blue: 0.15)
    private static let zoneRed    = Color(red: 0.95, green: 0.25, blue: 0.25)
    private static let unlitOpacity: Double = 0.15

    private static func zoneColor(progress: Float) -> Color {
        if progress <= 0.8  { return zoneGreen }
        if progress <= 0.9  { return zoneYellow }
        if progress <= 0.95 { return zoneOrange }
        return zoneRed
    }

    private func position(forDB db: Float) -> CGFloat {
        CGFloat(max(0, min(1, (db + 60) / 60)))
    }

    private var meter: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 2) {
                meterBar
                meterScale
            }
            clipIndicator
                .frame(height: 13)
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(panelOrange, lineWidth: 1))
    }

    private var meterBar: some View {
        HStack(spacing: Self.segmentSpacing) {
            ForEach(0..<Self.segmentCount, id: \.self) { i in
                let top  = Float(i + 1) / Float(Self.segmentCount)
                let bot  = Float(i)     / Float(Self.segmentCount)
                let color = Self.zoneColor(progress: top)
                // A segment lights when the RMS level reaches it, or when the
                // held peak falls within its range (gives the classic floating
                // peak-hold tick above the lit row).
                let rmsLit = top <= viewModel.rmsLevel
                let peakInSeg = viewModel.peakLevel > bot && viewModel.peakLevel <= top
                let isLit = rmsLit || peakInSeg
                Rectangle()
                    .fill(isLit ? color : color.opacity(Self.unlitOpacity))
            }
        }
        .frame(height: 13)
    }

    private var clipIndicator: some View {
        HStack(spacing: 2) {
            Circle()
                .fill(viewModel.clipDetected ? Color.red : Color.white.opacity(0.18))
                .frame(width: 6, height: 6)
                .overlay(Circle().stroke(panelOrange.opacity(0.7), lineWidth: 0.5))
                .shadow(color: viewModel.clipDetected ? .red.opacity(0.8) : .clear, radius: 3)
                .animation(.easeOut(duration: 0.08), value: viewModel.clipDetected)
            Text("CLIP")
                .font(.system(size: 7, weight: .semibold))
                .foregroundColor(viewModel.clipDetected ? .red : panelOrange.opacity(0.8))
        }
        .frame(width: 28, alignment: .trailing)
    }

    private var meterScale: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(meterTicks, id: \.db) { tick in
                    VStack(spacing: 1) {
                        Rectangle()
                            .fill(panelOrange.opacity(0.55))
                            .frame(width: 1, height: 2)
                        Text(tick.label)
                            .font(.system(size: 7, weight: .medium))
                            .foregroundColor(panelOrange.opacity(0.85))
                            .fixedSize()
                    }
                    .frame(width: 14)
                    .offset(x: geo.size.width * position(forDB: tick.db) - 7)
                }
            }
        }
        .frame(height: 10)
    }

    // MARK: - Other state views

    #if GCS_ENABLED
    private var uploadingView: some View {
        VStack(spacing: 12) {
            Text("Uploading…")
                .font(.title3)
                .foregroundColor(panelOrange)
            ProgressView(value: viewModel.uploadProgress)
                .progressViewStyle(.linear)
                .tint(panelOrange)
                .frame(width: 168)
            Text("\(Int(viewModel.uploadProgress * 100))%")
                .font(.headline)
                .foregroundColor(panelOrange)
                .monospacedDigit()
        }
    }
    #endif

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 4)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(panelOrange)
                .shadow(color: panelOrange.opacity(0.55), radius: 4)

            Text(message)
                .font(.system(size: 11, weight: .medium))
                .tracking(0.3)
                .foregroundColor(panelOrange)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)

            Button {
                viewModel.reset()
            } label: {
                Text("TRY AGAIN")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundColor(panelOrange)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.55))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(panelOrange, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            Spacer()
        }
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Device Picker Popover

private struct DevicePickerPopover: View {
    let devices: [AVCaptureDevice]
    let selectedID: String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("INPUT")
                .font(.system(size: 9, weight: .bold))
                .tracking(1.5)
                .foregroundColor(panelOrange.opacity(0.75))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

            ForEach(devices, id: \.uniqueID) { device in
                Button {
                    onSelect(device.uniqueID)
                } label: {
                    HStack {
                        Text(device.localizedName)
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                        Spacer()
                        if selectedID == device.uniqueID {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(panelOrange)
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
        .padding(.bottom, 6)
        .frame(minWidth: 200)
        .background(panelBlueDark)
        .preferredColorScheme(.dark)
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
                .foregroundColor(panelOrange)

            // Filename
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("FILENAME")
                HStack(spacing: 6) {
                    TextField("DoublEnder", text: $viewModel.filenameBase)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.55))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(panelOrange.opacity(0.55), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    Text("_<date>.\(viewModel.outputFormat.fileExtension)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(panelOrange.opacity(0.55))
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
                            .foregroundColor(panelOrange.opacity(0.35))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $viewModel.notes)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                }
                .frame(height: 56)
                .background(Color.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(panelOrange.opacity(0.55), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 3))
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
                .tint(panelOrange)
            }
        }
        .padding(16)
        .frame(width: 260)
        .background(panelBlueDark)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(1.2)
            .foregroundColor(panelOrange.opacity(0.75))
    }
}
