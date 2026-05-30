import SwiftUI

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
                isClipping: viewModel.isClipping,
                inputActive: popovers.showingInput,
                settingsActive: popovers.showingSettings,
                inputDisabled: viewModel.isCurrentlyRecording,
                settingsDisabled: viewModel.isCurrentlyRecording,
                onInputTap: { anchorView in
                    guard !viewModel.isCurrentlyRecording else { return }
                    popovers.toggleInput(
                        buttonView: anchorView,
                        content: AnyView(FaceplateDevicePickerPopover(
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
            viewModel.startRecording()
        default:
            break
        }
    }
}
