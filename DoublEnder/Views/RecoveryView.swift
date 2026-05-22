import SwiftUI
import AppKit

// Warm amber palette — matches UploadConfirmationView so every themed dialog
// in the app shares the same chassis-screen aesthetic.
/// Near-black warm background (#0D0800) — same as screen interior.
private let recBackground = Color(red: 0x0D/255, green: 0x08/255, blue: 0x00/255)
/// Amber card-edge stroke.
private let recBorder     = Color(red: 0xFF/255, green: 0xB3/255, blue: 0x47/255).opacity(0.45)
/// Warm amber (#FFD580) — title text, matches clock-digit colour.
private let recAmber      = Color(red: 0xFF/255, green: 0xD5/255, blue: 0x80/255)
/// Primary amber (#F5A623) — icon tint, button border + label.
private let recIcon       = Color(red: 0xF5/255, green: 0xA6/255, blue: 0x23/255)
/// Warm off-white body text (#F0E0C0).
private let recBodyText   = Color(red: 0xF0/255, green: 0xE0/255, blue: 0xC0/255)
/// Muted amber (#A0600A) — filename, secondary-weight info.
private let recFilename   = Color(red: 0xA0/255, green: 0x60/255, blue: 0x0A/255)
/// Very dark warm field background (#1A0A00).
private let recFieldBg    = Color(red: 0x1A/255, green: 0x0A/255, blue: 0x00/255)

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
        .background(recBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(recBorder, lineWidth: 1.5)
        )
        .shadow(color: Color(red: 0xC9/255, green: 0x6A/255, blue: 0x00/255).opacity(0.30), radius: 20)
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

    // MARK: - Themed building blocks (matched to UploadConfirmationView)

    private func icon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(recIcon)
            .shadow(color: recIcon.opacity(0.60), radius: 8)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(1.8)
            .foregroundColor(recAmber)
            .shadow(color: Color(red: 0xF5/255, green: 0xA6/255, blue: 0x23/255).opacity(0.85), radius: 6)
            .shadow(color: Color(red: 0xC8/255, green: 0x78/255, blue: 0x00/255).opacity(0.40), radius: 16)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .tracking(0.3)
            .foregroundColor(recBodyText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fileNameText(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(recFilename)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func pillButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundColor(recIcon)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 4).fill(recFieldBg))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(recIcon, lineWidth: 1.5))
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
