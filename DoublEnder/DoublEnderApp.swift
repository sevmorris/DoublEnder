import SwiftUI
import AppKit
import CoreText
import OSLog

private let logger = Logger(subsystem: "io.github.sevmorris.DoublEnder", category: "AppDelegate")

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
        #if GCS_ENABLED
        runPendingUploadCheckIfNeeded()
        #endif
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
        UserDefaults.standard.synchronize()
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
        guard let window = candidate ?? NSApp.windows.first else {
            logger.error("configureMainWindow: no window found — window chrome and delegate not applied")
            return
        }

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

    /// A PCM sidecar on disk means a previous recording never finalized —
    /// the matching .m4a (if any) is unplayable. Present a themed dialog
    /// per sidecar that re-wraps it into a valid WAV off the main thread.
    private func runCrashRecoveryIfNeeded() {
        let fm = FileManager.default
        let dir = RecorderViewModel.recordingsDirectory

        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }

        let sidecars = entries.filter { $0.pathExtension == PCMSidecar.pathExtension }
        guard !sidecars.isEmpty else { return }

        // Recovery is a gate the user must clear before using the app — keep
        // the main recorder window hidden until every sidecar is resolved,
        // then bring it forward. Untouched when no recovery is needed, so
        // the normal launch path has no flicker.
        mainWindow?.orderOut(nil)
        for sidecar in sidecars {
            presentRecoveryDialog(for: sidecar)
        }
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    #if GCS_ENABLED
    /// A persisted pending-upload path means a prior session's upload was
    /// interrupted. If the local file is still on disk, offer to finish it;
    /// stale/missing entries are cleared silently.
    private func runPendingUploadCheckIfNeeded() {
        let vm = RecorderViewModel.shared
        guard let path = vm.persistedPendingUploadPath else { return }

        guard FileManager.default.fileExists(atPath: path) else {
            vm.clearPendingUpload()
            return
        }

        let url = URL(fileURLWithPath: path)
        mainWindow?.orderOut(nil)
        let shouldUpload = PendingUploadPrompt.present(fileName: url.lastPathComponent)
        mainWindow?.makeKeyAndOrderFront(nil)

        if shouldUpload {
            vm.resumePendingUpload(fileURL: url)
        } else {
            vm.clearPendingUpload()
        }
    }
    #endif

    /// Runs a modal session for one sidecar. The modal run loop keeps the
    /// window — and its spinner — responsive while `RecoveryModel` does the
    /// conversion on a background queue.
    private func presentRecoveryDialog(for sidecar: URL) {
        let model = RecoveryModel(sidecarURL: sidecar)
        let hosting = NSHostingController(rootView: RecoveryView(model: model))

        let window = RecoveryWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.level = .modalPanel
        window.center()

        model.onFinished = { [weak window] in
            NSApp.stopModal()
            window?.orderOut(nil)
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
    }

    // MARK: - Fonts

    private func registerBundledFonts() {
        guard let url = Bundle.main.url(forResource: "DSEG7Classic-Regular", withExtension: "ttf") else {
            return
        }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

// MARK: - Recovery window

/// Borderless windows refuse key/main status by default, which would block
/// button clicks and keyboard focus in the modal recovery dialog.
final class RecoveryWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
