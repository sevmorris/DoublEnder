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
            autoRecordBadge
            warningBadge
            Spacer(minLength: FaceplateDesign.s(10))
            recordStopButton
            Spacer(minLength: FaceplateDesign.s(10))
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
        .onAppear {
            // The VM decides when to ask; the alert lives here, next to the
            // manual path's copy of it. Captures nothing but the view model,
            // which is the singleton the VM already is.
            viewModel.requestAutoRecordStart = { [weak viewModel] in
                guard let viewModel else { return .decline }
                if viewModel.shouldPromptForRecordingName {
                    guard let stem = Self.runNamePromptModal(
                        defaultName: viewModel.autoRecordGuestName
                    ) else { return .decline }
                    return .start(name: stem)
                }
                return Self.runStartConfirmModal() ? .start(name: nil) : .decline
            }
        }
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
        .padding(.top, FaceplateDesign.s(4))
    }

    private var versionInScreen: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let (numeric, suffix) = FaceplateDesign.splitVersionSuffix(version)
        return HStack(spacing: FaceplateDesign.s(5)) {
            Text("v\(numeric)\(suffix.uppercased())")
                .foregroundColor(FaceplateDesign.secondaryAmber)
            #if GCS_ENABLED
            // Persistent marker for local-only mode. The cloud LED alone is
            // ambiguous (dark also means "unreachable"), and a silently
            // disabled upload is exactly the failure a producer can't see.
            if !viewModel.cloudUploadEnabled {
                Text("LOCAL")
                    .foregroundColor(FaceplateDesign.activeAmber)
                    .help("Cloud upload is off — this recording stays on this Mac")
            }
            #endif
        }
        .font(FaceplateDesign.metadataFont)
        .lineLimit(1)
        .fixedSize()
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
                .font(FaceplateDesign.crtFont(size: FaceplateDesign.s(41)))
                .tracking(FaceplateDesign.s(3))
                .foregroundColor(FaceplateDesign.vpAmber)
                .shadow(color: FaceplateDesign.counterGlowInner, radius: FaceplateDesign.s(8))
                .shadow(color: FaceplateDesign.counterGlowOuter, radius: FaceplateDesign.s(22))
        }
        .frame(width: FaceplateDesign.vpContentWidth, height: FaceplateDesign.s(70))
        .clipShape(RoundedRectangle(cornerRadius: FaceplateDesign.s(6)))
        .overlay(RoundedRectangle(cornerRadius: FaceplateDesign.s(6)).stroke(FaceplateDesign.vpBorder, lineWidth: FaceplateDesign.s(1.5)))
        .shadow(color: .black.opacity(0.45), radius: FaceplateDesign.s(3), x: 0, y: FaceplateDesign.s(1))
    }

    // MARK: - Warning badge

    /// Countdown to an automatic start, with its own way out. Worded so the
    /// clock reads as information rather than a deadline: nothing is lost by
    /// letting it run out, and CANCEL is right there for when something is.
    @ViewBuilder private var autoRecordBadge: some View {
        if let remaining = viewModel.autoRecordCountdown {
            HStack(spacing: FaceplateDesign.s(8)) {
                // Zero-padded and monospaced so the row cannot move: a plain
                // "\(remaining)s" changes character count at 9 and changes
                // glyph width between digits, and since the row is centred,
                // either one makes the whole label twitch once a second.
                // Matches the counter above, which is already padded hh:mm:ss.
                Text("READY TO RECORD IN \(String(format: "%02d", remaining))S")
                    .font(.system(size: FaceplateDesign.s(12), weight: .semibold).monospacedDigit())
                    .tracking(FaceplateDesign.s(0.6))
                    .foregroundColor(FaceplateDesign.vpAmber)
                    .shadow(color: FaceplateDesign.counterGlowInner, radius: FaceplateDesign.s(5))

                Button("CANCEL") { viewModel.cancelAutoRecord() }
                    .buttonStyle(.plain)
                    .font(.system(size: FaceplateDesign.s(10), weight: .bold))
                    .tracking(FaceplateDesign.s(0.5))
                    // Deliberately quieter than the message — the countdown is
                    // the thing to read, the escape hatch is the thing to find.
                    .foregroundColor(FaceplateDesign.vpAmber.opacity(0.70))
                    .focusEffectDisabledIfAvailable()
            }
            .frame(height: FaceplateDesign.s(16))
            .padding(.top, FaceplateDesign.s(4))
        }
    }

    @ViewBuilder private var warningBadge: some View {
        if let msg = viewModel.recordingWarning {
            HStack(spacing: FaceplateDesign.s(4)) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: FaceplateDesign.s(9), weight: .semibold))
                Text(msg)
                    .font(.system(size: FaceplateDesign.s(9), weight: .medium))
                    .tracking(FaceplateDesign.s(0.4))
            }
            .foregroundColor(.yellow.opacity(0.80))
            .frame(height: FaceplateDesign.s(14))
            .padding(.top, FaceplateDesign.s(3))
        }
    }

    // MARK: - RECORD / STOP button

    private var recordStopButton: some View {
        Button { handleRecordTap() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: FaceplateDesign.s(6))
                    .fill(isRecordingState ? FaceplateDesign.stopFill : FaceplateDesign.recordIdleFill)
                // Both labels share one size so the type doesn't jump when the
                // button toggles. "PRESS TO RECORD" is the longer string and
                // sets the ceiling: it needs ~384pt at the old 41pt inside a
                // 295pt button, and 27pt is the largest size that fits.
                //
                // Two stacked lines were measured and are WORSE, not better —
                // the 72pt button height constrains stacked text (25pt max)
                // harder than the width constrains a single line (27pt).
                // Bigger type here means a taller button, not more lines.
                //
                // lineLimit + minimumScaleFactor guard the font fallback: a Mac
                // without Eurostile resolves panelFont to system-bold, which
                // renders these strings ~8% wider and would otherwise wrap or
                // clip on a guest's machine.
                Text(isRecordingState ? "PRESS TO STOP" : "PRESS TO RECORD")
                    .font(FaceplateDesign.panelFont(size: FaceplateDesign.s(27)))
                    .tracking(FaceplateDesign.s(3))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .foregroundColor(isRecordingState ? .white : FaceplateDesign.recordAccent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .multilineTextAlignment(.center)
                    // Cap-only text sits optically high; nudge to compensate.
                    .offset(y: FaceplateDesign.s(4))
            }
            .frame(width: FaceplateDesign.vpContentWidth, height: FaceplateDesign.s(72))
            .background(FaceplateDesign.vpSurface)
            .clipShape(RoundedRectangle(cornerRadius: FaceplateDesign.s(6)))
            .overlay(
                RoundedRectangle(cornerRadius: FaceplateDesign.s(6))
                    .stroke(
                        isRecordingState ? FaceplateDesign.vpBorder : FaceplateDesign.recordAccent,
                        lineWidth: FaceplateDesign.s(isRecordingState ? 1.5 : 2.0)
                    )
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabledIfAvailable()
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
            if viewModel.shouldPromptForRecordingName {
                if let stem = Self.runNamePromptModal(
                    defaultName: viewModel.autoRecordGuestName
                ) {
                    viewModel.autoRecordGuestName = stem
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
    /// 240pt so the total dialog lands around 280pt with the standard
    /// alert margins. Run-modal pattern matches the USB-detect alert in
    /// RecorderViewModel — the faceplate window is borderless and can't
    /// route sheet button clicks.
    ///
    /// Returns the sanitized name on "Start Recording", or `nil` on Cancel
    /// or sanitized-to-empty input.
    /// Static so the closure stored on the view model captures no view — an
    /// instance method would have retained `popovers` and the `isStopping`
    /// binding for the life of the singleton.
    @MainActor
    private static func runNamePromptModal(defaultName: String = "") -> String? {
        let alert = NSAlert()
        alert.window.appearance = NSAppearance(named: .darkAqua)
        alert.alertStyle = .informational
        alert.messageText = "Who is recording?"

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Your name"
        field.stringValue = defaultName
        alert.accessoryView = field

        let startButton = alert.addButton(withTitle: "Start Recording")
        let cancelButton = alert.addButton(withTitle: "Cancel")
        // Pre-filled from last time means the guest can just hit Return.
        startButton.isEnabled = !RecorderViewModel
            .sanitizedRecordingName(from: defaultName).isEmpty
        // Strip Return from Start while it's disabled — otherwise Cocoa
        // visually transfers the default-button ring to Cancel, making
        // Return dismiss with Cancel. Restored when the name is non-empty.
        startButton.keyEquivalent = startButton.isEnabled ? "\r" : ""
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

    /// Consent step for builds with no name prompt (Local, and Cloud with
    /// upload switched off). Same decision, without the field.
    @MainActor
    private static func runStartConfirmModal() -> Bool {
        let alert = NSAlert()
        alert.window.appearance = NSAppearance(named: .darkAqua)
        alert.alertStyle = .informational
        alert.messageText = "Start recording?"
        alert.informativeText = "DoublEnder is ready and your input is set."
        alert.addButton(withTitle: "Start Recording")
        alert.addButton(withTitle: "Not Now").keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }
}
