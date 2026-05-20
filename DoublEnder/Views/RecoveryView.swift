import SwiftUI
import AppKit

private let secondarySurface = Color(red: 0x2A/255, green: 0x2A/255, blue: 0x2A/255)
private let secondaryText    = Color(red: 0xE8/255, green: 0xE8/255, blue: 0xE8/255)
private let secondaryFieldBg = Color(red: 0x14/255, green: 0x14/255, blue: 0x14/255)
// Phosphor green — matches the counter digits in the main panel.
private let accentBlue       = Color(red: 0x39/255, green: 0xFF/255, blue: 0x14/255)

/// Drives the crash-recovery dialog through its phases. The expensive
/// sidecar→WAV conversion runs off the main thread so the window keeps
/// animating and never looks frozen, however long the recording is.
/// Phase mutations always land on the main thread: the synchronous
/// actions are invoked from SwiftUI button taps, and the background
/// conversion hops back via `DispatchQueue.main.async`.
final class RecoveryModel: ObservableObject {
    enum Phase: Equatable {
        case prompt
        case working
        case success(URL)
        case failure(String)
    }

    @Published private(set) var phase: Phase = .prompt

    let sidecarURL: URL
    let mainFileURL: URL

    /// Invoked when this sidecar is fully handled (recovered, deleted, or
    /// dismissed) so the host can close the window and advance to the next.
    var onFinished: (() -> Void)?

    init(sidecarURL: URL) {
        self.sidecarURL = sidecarURL
        self.mainFileURL = PCMSidecar.mainOutputURL(for: sidecarURL)
    }

    var fileName: String { mainFileURL.lastPathComponent }

    func recover() {
        phase = .working
        let sidecar = sidecarURL
        let mainFile = mainFileURL

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Phase
            do {
                let recovered = try PCMSidecar.recoverToWAV(sidecarURL: sidecar)
                // Success — drop the sidecar and the unplayable partial.
                try? FileManager.default.removeItem(at: sidecar)
                try? FileManager.default.removeItem(at: mainFile)
                outcome = .success(recovered)
            } catch {
                // Failure — leave the sidecar in place so nothing is lost.
                outcome = .failure(error.localizedDescription)
            }
            DispatchQueue.main.async { self.phase = outcome }
        }
    }

    func deleteWithoutRecovering() {
        try? FileManager.default.removeItem(at: sidecarURL)
        try? FileManager.default.removeItem(at: mainFileURL)
        onFinished?()
    }

    func revealInFinder() {
        if case .success(let url) = phase {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        onFinished?()
    }

    func dismiss() {
        onFinished?()
    }
}

struct RecoveryView: View {
    @ObservedObject var model: RecoveryModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .frame(width: 380, height: 240)
        .background(secondarySurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accentBlue, lineWidth: 1.5)
        )
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .prompt:
            promptContent
        case .working:
            workingContent
        case .success(let url):
            successContent(url)
        case .failure(let message):
            failureContent(message)
        }
    }

    // MARK: - Phases

    private var promptContent: some View {
        VStack(spacing: 14) {
            icon("exclamationmark.triangle.fill")
            title("UNSAVED RECORDING")
            bodyText("A recording from a previous session was interrupted before it could be saved. DoublEnder can recover it as a WAV file.")
            fileNameText(model.fileName)
            HStack(spacing: 10) {
                pillButton("RECOVER") { model.recover() }
                pillButton("DELETE") { model.deleteWithoutRecovering() }
            }
            .padding(.top, 2)
        }
    }

    private var workingContent: some View {
        VStack(spacing: 16) {
            Spinner()
                .frame(width: 32, height: 32)
            title("RECOVERING RECORDING…")
            bodyText("Re-wrapping the audio into a WAV file. This can take a moment for a long recording.")
        }
    }

    private func successContent(_ url: URL) -> some View {
        VStack(spacing: 14) {
            icon("checkmark.seal.fill")
            title("RECOVERY COMPLETE")
            bodyText("The recording was saved as:")
            fileNameText(url.lastPathComponent)
            HStack(spacing: 10) {
                pillButton("REVEAL IN FINDER") { model.revealInFinder() }
                pillButton("CLOSE") { model.dismiss() }
            }
            .padding(.top, 2)
        }
    }

    private func failureContent(_ message: String) -> some View {
        VStack(spacing: 14) {
            icon("exclamationmark.triangle.fill")
            title("RECOVERY FAILED")
            bodyText("The recording could not be recovered: \(message)\n\nThe recovery file has been left in place so nothing is lost.")
            pillButton("CLOSE") { model.dismiss() }
                .padding(.top, 2)
        }
    }

    // MARK: - Themed building blocks

    private func icon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(accentBlue)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(1.8)
            .foregroundColor(secondaryText)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .tracking(0.3)
            .foregroundColor(secondaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fileNameText(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(secondaryText.opacity(0.65))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func pillButton(_ label: String, action: @escaping () -> Void) -> some View {
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

/// Indeterminate spinner — the requested `NSProgressIndicator` rather than
/// SwiftUI's `ProgressView`, kept animating by the modal run loop.
private struct Spinner: NSViewRepresentable {
    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .regular
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        return indicator
    }

    func updateNSView(_ nsView: NSProgressIndicator, context: Context) {}
}
