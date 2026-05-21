#if GCS_ENABLED
import SwiftUI
import AppKit

private let secondarySurface = Color(red: 0x2A/255, green: 0x2A/255, blue: 0x2A/255)
private let secondaryText    = Color(red: 0xE8/255, green: 0xE8/255, blue: 0xE8/255)
private let secondaryFieldBg = Color(red: 0x14/255, green: 0x14/255, blue: 0x14/255)
// Phosphor green — matches the counter digits in the main panel.
private let appAccent       = Color(red: 0x39/255, green: 0xFF/255, blue: 0x14/255)
// Muted green border — matches the viewport screen boxes (#7FBF7F).
private let vpBorder        = Color(red: 127/255,  green: 191/255,  blue: 127/255)

/// Upload-result confirmation for the DoublEnder Cloud build.
///
/// macOS user notifications can't be forced to persist until dismissed
/// (that's the user-controlled Alerts/Banners setting) and require a
/// per-bundle authorization that may never have been granted. To
/// guarantee the confirmation always appears and stays until acknowledged,
/// it's an app-controlled modal — same borderless themed window and
/// `NSApp.runModal` mechanics as the crash-recovery dialog.
struct UploadConfirmationView: View {
    let success: Bool
    let fileName: String
    let onAcknowledge: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            icon(success ? "checkmark.icloud.fill" : "exclamationmark.icloud.fill")
            title("DoublEnder Cloud")
            bodyText(success
                     ? "Saved to Desktop and uploaded."
                     : "Saved to Desktop. Upload failed.")
            fileNameText(fileName)
            pillButton("OK") { onAcknowledge() }
                .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .frame(width: 380, height: 240)
        .background(secondarySurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(vpBorder, lineWidth: 1.5)
        )
        .preferredColorScheme(.dark)
    }

    // MARK: - Themed building blocks (matched to RecoveryView)

    private func icon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(appAccent)
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
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(appAccent, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

/// Borderless windows refuse key/main status by default, which would block
/// the OK button and keyboard focus in the modal.
final class UploadConfirmationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Presents the confirmation as a blocking modal on the main thread and
/// returns only once the user clicks OK. Must be called on the main actor.
enum UploadConfirmation {
    static func present(success: Bool, fileName: String) {
        let window = UploadConfirmationWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = UploadConfirmationView(success: success, fileName: fileName) { [weak window] in
            NSApp.stopModal()
            window?.orderOut(nil)
        }
        window.contentViewController = NSHostingController(rootView: view)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.level = .modalPanel
        centerOnAppScreen(window)

        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
    }

    /// Centre `window` on the same screen that the main app window occupies,
    /// falling back to the primary screen (m17 — multi-monitor placement).
    fileprivate static func centerOnAppScreen(_ window: NSWindow) {
        let screen = NSApp.windows
            .first(where: { !$0.isMiniaturized && $0.isVisible && $0 !== window })?.screen
            ?? NSScreen.main
        guard let screen else { window.center(); return }
        let sf = screen.visibleFrame
        let wf = window.frame
        window.setFrameOrigin(NSPoint(x: sf.midX - wf.width / 2, y: sf.midY - wf.height / 2))
    }
}

// MARK: - Pending-upload launch prompt

/// Shown at launch when a prior session left an upload unfinished. Two
/// choices, themed to match the confirmation/recovery dialogs.
struct PendingUploadView: View {
    let fileName: String
    let onUpload: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            icon("arrow.up.circle")
            title("DoublEnder Cloud")
            bodyText("A recording wasn't uploaded last session. Upload now?")
            fileNameText(fileName)
            HStack(spacing: 10) {
                pillButton("UPLOAD") { onUpload() }
                pillButton("SKIP") { onSkip() }
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .frame(width: 380, height: 240)
        .background(secondarySurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(vpBorder, lineWidth: 1.5)
        )
        .preferredColorScheme(.dark)
    }

    private func icon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(appAccent)
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
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(appAccent, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

/// Presents the pending-upload prompt as a blocking modal and returns
/// `true` if the user chose Upload, `false` if Skip. Call on the main actor.
enum PendingUploadPrompt {
    static func present(fileName: String) -> Bool {
        var choseUpload = false
        let window = UploadConfirmationWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = PendingUploadView(
            fileName: fileName,
            onUpload: { [weak window] in
                choseUpload = true
                NSApp.stopModal()
                window?.orderOut(nil)
            },
            onSkip: { [weak window] in
                choseUpload = false
                NSApp.stopModal()
                window?.orderOut(nil)
            }
        )
        window.contentViewController = NSHostingController(rootView: view)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.level = .modalPanel
        UploadConfirmation.centerOnAppScreen(window)

        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        return choseUpload
    }
}
#endif
