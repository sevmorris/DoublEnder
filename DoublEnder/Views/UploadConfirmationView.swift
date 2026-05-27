import SwiftUI
import AppKit

// Warm amber palette — mirrors the faceplate screen aesthetic.
/// Near-black warm background (#0D0800) — same as screen interior.
private let dlgBackground = Color(red: 0x0D/255, green: 0x08/255, blue: 0x00/255)
/// Amber card-edge stroke.
private let dlgBorder     = Color(red: 0xFF/255, green: 0xB3/255, blue: 0x47/255).opacity(0.45)
/// Warm amber (#FFD580) — title text, matches clock-digit colour.
private let dlgAmber      = Color(red: 0xFF/255, green: 0xD5/255, blue: 0x80/255)
/// Primary amber (#F5A623) — icon tint, button border + label.
private let dlgIcon       = Color(red: 0xF5/255, green: 0xA6/255, blue: 0x23/255)
/// Warm off-white body text (#F0E0C0).
private let dlgBodyText   = Color(red: 0xF0/255, green: 0xE0/255, blue: 0xC0/255)
/// Muted amber (#A0600A) — filename, secondary-weight info.
private let dlgFilename   = Color(red: 0xA0/255, green: 0x60/255, blue: 0x0A/255)
/// Very dark warm field background (#1A0A00).
private let dlgFieldBg    = Color(red: 0x1A/255, green: 0x0A/255, blue: 0x00/255)

/// Shared themed confirmation content for Local save and Cloud upload dialogs.
private struct ThemedConfirmationView: View {
    let iconName: String
    let title: String
    let message: String
    let fileName: String
    let onAcknowledge: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            icon(iconName)
            titleText(title)
            bodyText(message)
            fileNameText(fileName)
            pillButton("OK") { onAcknowledge() }
                .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .frame(width: 380, height: 240)
        .background(dlgBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(dlgBorder, lineWidth: 1.5)
        )
        .shadow(color: Color(red: 0xC9/255, green: 0x6A/255, blue: 0x00/255).opacity(0.30), radius: 20)
        .preferredColorScheme(.dark)
    }

    private func icon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(dlgIcon)
            .shadow(color: dlgIcon.opacity(0.60), radius: 8)
    }

    private func titleText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(1.8)
            .foregroundColor(dlgAmber)
            .shadow(color: Color(red: 0xF5/255, green: 0xA6/255, blue: 0x23/255).opacity(0.85), radius: 6)
            .shadow(color: Color(red: 0xC8/255, green: 0x78/255, blue: 0x00/255).opacity(0.40), radius: 16)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .tracking(0.3)
            .foregroundColor(dlgBodyText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fileNameText(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(dlgFilename)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func pillButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundColor(dlgIcon)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 4).fill(dlgFieldBg))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(dlgIcon, lineWidth: 1.5))
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

/// Presents a blocking themed confirmation on the main thread.
private enum ThemedConfirmation {
    static func present(iconName: String, title: String, message: String, fileName: String) {
        let window = UploadConfirmationWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = ThemedConfirmationView(
            iconName: iconName,
            title: title,
            message: message,
            fileName: fileName
        ) { [weak window] in
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

/// Local recording-save confirmation — same app-controlled modal as Cloud so
/// success is always visible even when notification permissions are denied.
enum RecordingSavedConfirmation {
    static func present(fileName: String) {
        ThemedConfirmation.present(
            iconName: "checkmark.circle.fill",
            title: "DoublEnder",
            message: "Recording saved to Desktop.",
            fileName: fileName
        )
    }
}

#if GCS_ENABLED
/// Upload-result confirmation for the DoublEnder Cloud build.
enum UploadConfirmation {
    static func present(success: Bool, fileName: String) {
        ThemedConfirmation.present(
            iconName: success ? "checkmark.icloud.fill" : "exclamationmark.icloud.fill",
            title: "DoublEnder Cloud",
            message: success
                ? "Saved to Desktop and uploaded."
                : "Saved to Desktop. Upload failed.",
            fileName: fileName
        )
    }

    /// Exposed for PendingUploadPrompt centreing.
    fileprivate static func centerOnAppScreen(_ window: NSWindow) {
        ThemedConfirmation.centerOnAppScreen(window)
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
        .background(dlgBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(dlgBorder, lineWidth: 1.5)
        )
        .shadow(color: Color(red: 0xC9/255, green: 0x6A/255, blue: 0x00/255).opacity(0.30), radius: 20)
        .preferredColorScheme(.dark)
    }

    private func icon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(dlgIcon)
            .shadow(color: dlgIcon.opacity(0.60), radius: 8)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(1.8)
            .foregroundColor(dlgAmber)
            .shadow(color: Color(red: 0xF5/255, green: 0xA6/255, blue: 0x23/255).opacity(0.85), radius: 6)
            .shadow(color: Color(red: 0xC8/255, green: 0x78/255, blue: 0x00/255).opacity(0.40), radius: 16)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .tracking(0.3)
            .foregroundColor(dlgBodyText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fileNameText(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(dlgFilename)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func pillButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundColor(dlgIcon)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 4).fill(dlgFieldBg))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(dlgIcon, lineWidth: 1.5))
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
