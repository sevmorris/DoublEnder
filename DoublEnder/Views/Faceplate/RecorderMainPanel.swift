import SwiftUI
import AppKit

// MARK: - Main recording panel

struct RecorderMainPanel: View {
    @ObservedObject var viewModel: RecorderViewModel
    @ObservedObject var popovers: FaceplatePopoverManager
    @Binding var isStopping: Bool

    private var isRecordingState: Bool {
        if case .recording = viewModel.state { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: FaceplateDesign.vpInnerPad)
            counterWindow
            warningBadge
            Spacer(minLength: 10)
            recordStopButton
            Spacer(minLength: 10)
            FaceplateMeterRow(
                level: viewModel.meterLevel,
                inputActive: popovers.showingInput,
                settingsActive: popovers.showingSettings,
                inputDisabled: viewModel.isCurrentlyRecording,
                settingsDisabled: viewModel.isCurrentlyRecording,
                onInputTap: { anchorView in
                    guard !viewModel.isCurrentlyRecording else { return }
                    popovers.toggleInput(
                        buttonView: anchorView,
                        content: AnyView(FaceplateDevicePickerPopover(
                            microphones: viewModel.hardwareInputDevices,
                            selectedID: viewModel.selectedInputDeviceID,
                            onSelect: { id in
                                viewModel.selectedInputDeviceID = id
                                popovers.closeInput()
                            }
                        ))
                    )
                },
                onSettingsTap: { anchorView in
                    guard !viewModel.isCurrentlyRecording else { return }
                    popovers.toggleSettings(
                        buttonView: anchorView,
                        content: AnyView(FaceplateSettingsPopover(viewModel: viewModel))
                    )
                }
            )
            deviceLabelRow
            Spacer(minLength: FaceplateDesign.vpInnerPad)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom info row

    private var deviceLabelRow: some View {
        ZStack {
            Text(viewModel.boundInputDeviceName ?? "—")
                .font(FaceplateDesign.metadataFont)
                .foregroundColor(FaceplateDesign.secondaryAmber)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .center)

            versionInScreen
                .frame(maxWidth: .infinity, alignment: .leading)

            writeIndicator
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: FaceplateDesign.vpContentWidth)
        .padding(.top, 4)
    }

    private var versionInScreen: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let (numeric, suffix) = FaceplateDesign.splitVersionSuffix(version)
        return Text("v\(numeric)\(suffix.uppercased())")
            .font(FaceplateDesign.metadataFont)
            .foregroundColor(FaceplateDesign.secondaryAmber)
            .lineLimit(1)
    }

    private var writeIndicator: some View {
        Text("WRITING")
            .font(FaceplateDesign.metadataFont)
            .foregroundColor(viewModel.isWritingData ? FaceplateDesign.activeAmber : FaceplateDesign.idleWritingAmber)
            .help("Audio is being written to file")
    }

    // MARK: - Counter window

    private var counterWindow: some View {
        ZStack {
            FaceplateDesign.vpSurface
            Text(viewModel.recordingTime.hhmmss)
                .font(FaceplateDesign.crtFont(size: 41))
                .tracking(3)
                .foregroundColor(FaceplateDesign.vpAmber)
                .shadow(color: FaceplateDesign.counterGlowInner, radius: 8)
                .shadow(color: FaceplateDesign.counterGlowOuter, radius: 22)
        }
        .frame(width: FaceplateDesign.vpContentWidth, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(FaceplateDesign.vpBorder, lineWidth: 1.5))
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

    private var recordStopButton: some View {
        Button { handleRecordTap() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isRecordingState ? FaceplateDesign.stopFill : FaceplateDesign.recordIdleFill)
                Text(isRecordingState ? "STOP" : "RECORD")
                    .font(FaceplateDesign.panelFont(size: 41))
                    .tracking(3)
                    .foregroundColor(isRecordingState ? .white : FaceplateDesign.recordAccent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .multilineTextAlignment(.center)
                    .offset(y: 6)
            }
            .frame(width: FaceplateDesign.vpContentWidth, height: 72)
            .background(FaceplateDesign.vpSurface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isRecordingState ? FaceplateDesign.vpBorder : FaceplateDesign.recordAccent,
                        lineWidth: isRecordingState ? 1.5 : 2.0
                    )
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isStopping || (!isRecordingState && !viewModel.canStartRecording))
    }

    private func handleRecordTap() {
        switch viewModel.state {
        case .recording:
            guard !isStopping else { return }
            isStopping = true
            viewModel.stopRecording { isStopping = false }
        case .selectingMic, .ready:
            guard viewModel.canStartRecording else { return }
            if RecorderViewModel.requiresRecordingNameAtStart {
                if let stem = runNamePromptModal() {
                    viewModel.startRecording(nameOverride: stem)
                }
            } else {
                viewModel.startRecording()
            }
        default:
            break
        }
    }

    /// Compact NSAlert with a fixed-width accessory text field. Replaces the
    /// prior SwiftUI `.alert` which inflated to the host window's width —
    /// SwiftUI's macOS alert bridge sizes accessory views to their preferred
    /// (unbounded) intrinsic width. NSAlert lets us pin the accessory at
    /// 340pt so the total dialog lands around 380pt with the standard
    /// alert margins. Run-modal pattern matches the USB-detect alert in
    /// RecorderViewModel — the faceplate window is borderless and can't
    /// route sheet button clicks.
    ///
    /// Returns the sanitized name on "Start Recording", or `nil` on Cancel
    /// or sanitized-to-empty input.
    @MainActor
    private func runNamePromptModal() -> String? {
        let alert = NSAlert()
        alert.window.appearance = NSAppearance(named: .darkAqua)
        alert.alertStyle = .informational
        alert.messageText = "Name this recording"

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "Your name"
        alert.accessoryView = field

        let startButton = alert.addButton(withTitle: "Start Recording")
        let cancelButton = alert.addButton(withTitle: "Cancel")
        startButton.isEnabled = false
        // Strip Return from Start while it's disabled — otherwise Cocoa
        // visually transfers the default-button ring to Cancel, making
        // Return dismiss with Cancel. Restored when the name is non-empty.
        startButton.keyEquivalent = ""
        cancelButton.keyEquivalent = "\u{1b}"

        let observer = NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification,
            object: field, queue: .main
        ) { _ in
            let stem = RecorderViewModel.sanitizedRecordingName(from: field.stringValue)
            let valid = !stem.isEmpty
            startButton.isEnabled = valid
            startButton.keyEquivalent = valid ? "\r" : ""
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        DispatchQueue.main.async { alert.window.makeFirstResponder(field) }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let stem = RecorderViewModel.sanitizedRecordingName(from: field.stringValue)
        return stem.isEmpty ? nil : stem
    }
}
