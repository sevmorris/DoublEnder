import AppKit

/// What an update shows while it runs.
@MainActor
protocol UpdateProgressShowing: AnyObject {
    func showProgress(_ message: String, fraction: Double?)
    func bringForward()
    func close()
}

/// The window an update shows while it runs: a line, a bar and one button,
/// Cancel for an update the user asked for and Skip for Cloud's at launch. It
/// has no close button: at launch it is the app's only window, and closing
/// that would quit the app.
///
/// It is not modal, on purpose. The update runs on the main actor, and a modal
/// run loop started inside a main actor task stops the main queue (see
/// `MainRunLoop`), so the download could never report back. It is also why the
/// app stays usable while an update downloads.
@MainActor
final class UpdatePanel: NSObject, UpdateProgressShowing {
    private let window: NSWindow
    private let label = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    var onButton: (() -> Void)?
    /// Closed or turned transparent: never brought back.
    private var retired = false

    init(title: String, buttonTitle: String) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 118),
                          styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true

        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1

        let button = NSButton(title: buttonTitle, target: self, action: #selector(buttonPressed))
        button.bezelStyle = .push
        button.keyEquivalent = "\u{1b}"

        guard let content = window.contentView else { return }
        for view in [label, bar, button] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            button.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
            button.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            button.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    /// On the screen the app is on: `center()` always picks the primary one.
    func show() {
        let screen = NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0 !== window }?.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
        } else {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func bringForward() {
        guard !retired else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Gone from the screen but still on it as far as AppKit knows, so it does
    /// not count as the last window closed, which would quit the app.
    func makeTransparent() {
        retired = true
        bar.stopAnimation(nil)
        window.ignoresMouseEvents = true
        window.alphaValue = 0
    }

    func close() {
        retired = true
        bar.stopAnimation(nil)
        window.orderOut(nil)
        window.close()
    }

    func showProgress(_ message: String, fraction: Double?) {
        label.stringValue = message
        if let fraction {
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
            bar.doubleValue = fraction
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
    }

    @objc private func buttonPressed() {
        onButton?()
    }
}

/// The updater's dialogs, as NSAlerts in the app's dark appearance. Each runs
/// its own modal session; the coordinator decides when, through `ModalGate`.
@MainActor
final class AlertUpdatePresenter: UpdatePresenting {

    func offer(_ offer: UpdateOffer) -> UpdateOfferChoice {
        let alert = makeAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "\(offer.appName) \(offer.version) is available."
        if let obstacle = offer.obstacle {
            alert.informativeText += " " + obstacle
        }
        alert.addButton(withTitle: offer.canInstall ? "Update and Relaunch" : "Download")
        if offer.hasReleaseNotes {
            alert.addButton(withTitle: "Release Notes")
        }
        alert.addButton(withTitle: "Not Now")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return offer.canInstall ? .install : .download
        case .alertSecondButtonReturn where offer.hasReleaseNotes:
            return .releaseNotes
        default:
            return .notNow
        }
    }

    func confirmRelaunch(appName: String, version: String) -> Bool {
        let alert = makeAlert()
        alert.messageText = "\(appName) \(version) Is Ready to Install"
        alert.informativeText = "Relaunch now to finish updating, or choose Not Now to update later."
        alert.addButton(withTitle: "Relaunch Now")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func failure(appName: String, message: String) -> Bool {
        let alert = makeAlert()
        alert.messageText = "Couldn't Install the Update"
        alert.informativeText = "\(message) \(appName) has not changed. You can download the new version and install it yourself."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func inform(title: String, text: String) {
        let alert = makeAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func makeProgress(title: String, buttonTitle: String, onButton: @escaping () -> Void) -> UpdateProgressShowing {
        let panel = UpdatePanel(title: title, buttonTitle: buttonTitle)
        panel.onButton = onButton
        panel.show()
        return panel
    }

    private func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.window.appearance = NSAppearance(named: .darkAqua)
        return alert
    }
}
