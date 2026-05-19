#if GCS_ENABLED
import SwiftUI
import AppKit

private let panelBlue = Color(red: 0.13, green: 0.34, blue: 0.58)
private let panelOrange = Color(red: 0.93, green: 0.56, blue: 0.22)

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
        .background(panelBlue)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(panelOrange, lineWidth: 2)
        )
        .preferredColorScheme(.dark)
    }

    // MARK: - Themed building blocks (matched to RecoveryView)

    private func icon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(panelOrange)
            .shadow(color: panelOrange.opacity(0.55), radius: 4)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(1.8)
            .foregroundColor(panelOrange)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .tracking(0.3)
            .foregroundColor(panelOrange)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fileNameText(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(panelOrange.opacity(0.7))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func pillButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundColor(panelOrange)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(panelOrange, lineWidth: 1))
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
        window.center()

        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
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
        .background(panelBlue)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(panelOrange, lineWidth: 2)
        )
        .preferredColorScheme(.dark)
    }

    private func icon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(panelOrange)
            .shadow(color: panelOrange.opacity(0.55), radius: 4)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(1.8)
            .foregroundColor(panelOrange)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .tracking(0.3)
            .foregroundColor(panelOrange)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fileNameText(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(panelOrange.opacity(0.7))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func pillButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundColor(panelOrange)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(panelOrange, lineWidth: 1))
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
        window.center()

        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        return choseUpload
    }
}
#endif
