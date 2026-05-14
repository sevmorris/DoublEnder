import SwiftUI
import AppKit
import CoreText

@main
struct DoublEnderApp: App {
    // AppDelegate owns window chrome, quit intercept, and crash recovery so
    // the window is fully borderless/transparent before its first paint —
    // eliminating the chrome flash that the old WindowChromeStripper produced.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)   // fixed-size: content frame enforces 288×276
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await checkForUpdates() }
                }
            }

            CommandGroup(replacing: .help) {
                Button("DoublEnder Help") {
                    openWindow(id: "help")
                }
                .keyboardShortcut("?", modifiers: .command)

                Divider()

                Button("Send Feedback…") {
                    if let url = URL(string: "https://sevmorris.github.io/DoublEnder/") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button("Report an Issue…") {
                    if let url = URL(string: "https://github.com/sevmorris/DoublEnder/issues/new") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        Window("DoublEnder Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private weak var mainWindow: NSWindow?

    /// Side-effect-free setup that should run before any window appears.
    func applicationWillFinishLaunching(_ notification: Notification) {
        registerBundledFonts()
        NotificationService.shared.configure()
    }

    /// Windows exist but haven't been ordered front yet — configure the main
    /// window here so it's borderless/transparent on first paint.
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainWindow()
        runCrashRecoveryIfNeeded()
        Task { await checkForUpdates(silent: true) }
    }

    /// Single-window app — closing the only window should quit (and route
    /// through `applicationShouldTerminate` for the recording check).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Final cleanup on clean termination — wipe session-scoped settings
    /// (custom filename, notes) so the next launch starts fresh.
    func applicationWillTerminate(_ notification: Notification) {
        RecorderViewModel.shared.clearSessionSettings()
    }

    /// Quit intercept: if recording, surface the save/discard/cancel choice
    /// before allowing termination.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard RecorderViewModel.shared.isCurrentlyRecording else {
            return .terminateNow
        }
        presentRecordingInProgressAlert()
        return .terminateLater
    }

    /// ⌘W on the borderless window routes through here. We re-route to
    /// `terminate` so there's a single quit confirmation path.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    // MARK: - Main window configuration

    private func configureMainWindow() {
        // The help window is created lazily on first open, so at launch the
        // first (and only) window is the main content window.
        let candidate = NSApp.windows.first { $0.identifier?.rawValue != "help" && $0.contentView != nil }
        guard let window = candidate ?? NSApp.windows.first else { return }

        mainWindow = window
        window.delegate = self
        window.styleMask = [.borderless, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }

    // MARK: - Quit-during-recording alert

    private func presentRecordingInProgressAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Recording in progress"
        alert.informativeText = "Stopping now will save what has been recorded so far. Quitting without saving will lose the current recording."
        alert.addButton(withTitle: "Stop & Save")           // .alertFirstButtonReturn
        alert.addButton(withTitle: "Quit Without Saving")   // .alertSecondButtonReturn
        alert.addButton(withTitle: "Cancel")                // .alertThirdButtonReturn

        let response = alert.runModal()
        let vm = RecorderViewModel.shared

        switch response {
        case .alertFirstButtonReturn:
            // Finalize the writer, then continue termination once the file
            // is closed.
            vm.stopRecording {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        case .alertSecondButtonReturn:
            // Cancel the writer and drop the partial file before quitting.
            vm.abortRecording {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        default:
            NSApp.reply(toApplicationShouldTerminate: false)
        }
    }

    // MARK: - Crash recovery

    private func runCrashRecoveryIfNeeded() {
        let defaults = UserDefaults.standard
        let inProgress = defaults.bool(forKey: RecorderViewModel.inProgressFlagKey)
        let path = defaults.string(forKey: RecorderViewModel.inProgressPathKey) ?? ""

        // Always clear the flag at the end — even if we don't show a dialog —
        // so a missing file doesn't haunt future launches.
        defer {
            defaults.removeObject(forKey: RecorderViewModel.inProgressFlagKey)
            defaults.removeObject(forKey: RecorderViewModel.inProgressPathKey)
        }

        guard inProgress, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unsaved recording found"
        alert.informativeText = "A recording from a previous session was not saved cleanly. Would you like to keep it?\n\n\(url.lastPathComponent)"
        alert.addButton(withTitle: "Keep File")
        alert.addButton(withTitle: "Delete")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        default:
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Fonts

    private func registerBundledFonts() {
        guard let url = Bundle.main.url(forResource: "DSEG7Classic-Regular", withExtension: "ttf") else {
            return
        }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}
