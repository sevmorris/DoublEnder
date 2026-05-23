import SwiftUI
import AppKit
import CoreText
import OSLog

private let logger = Logger(subsystem: "io.github.sevmorris.DoublEnder", category: "AppDelegate")

@main
struct DoublEnderApp: App {
    // AppDelegate owns window chrome, quit intercept, and crash recovery so
    // the window is fully borderless/transparent before its first paint —
    // eliminating the chrome flash an earlier post-paint cleanup pass produced.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            #if GCS_ENABLED
            CloudContentView()
            #else
            ContentView()
            #endif
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)   // fixed-size: content frame enforces 320×338
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
        // m5: clear session-scoped settings (custom filename) before the VM
        // is initialised — this is the only reliable path that also runs after
        // a crash or force-quit, where applicationWillTerminate never fires.
        RecorderViewModel.eraseSessionDefaults()
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
    /// Also wiped at `applicationWillFinishLaunching` to cover crashes.
    func applicationWillTerminate(_ notification: Notification) {
        RecorderViewModel.shared.clearSessionSettings()
        // synchronize() has been a documented no-op since macOS 10.12 —
        // the OS flushes UserDefaults automatically. Removed (m6).
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
        // .fullSizeContentView is only meaningful for titled windows; on a
        // borderless window it is a no-op but has been observed to leave a
        // stale chrome layer active in some builds — drop it.
        // titlebarAppearsTransparent is also redundant for .borderless.
        window.styleMask = [.borderless]
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true

        // ── 1. Hosting-view layer ────────────────────────────────────────────
        // Cast explicitly to the concrete NSHostingView generic so we are certain
        // we are clearing the SwiftUI hosting view's own CALayer, not a wrapper.
        // SwiftUI sometimes initialises this layer with a non-zero fill colour
        // which shows through wherever the frame image has transparent pixels
        // (the rounded outer corners), most visibly in the bottom-right.
        // The cast target differs by build: CloudContentView for GCS_ENABLED,
        // ContentView for the public app.
        #if GCS_ENABLED
        let hostingViewCleared = (window.contentView as? NSHostingView<CloudContentView>)
            .map { hv -> Bool in
                hv.wantsLayer = true
                hv.layer?.backgroundColor = CGColor.clear
                hv.layer?.isOpaque = false
                return true
            } ?? false
        #else
        let hostingViewCleared = (window.contentView as? NSHostingView<ContentView>)
            .map { hv -> Bool in
                hv.wantsLayer = true
                hv.layer?.backgroundColor = CGColor.clear
                hv.layer?.isOpaque = false
                return true
            } ?? false
        #endif
        if !hostingViewCleared {
            // Fallback for any build variant where the generic cast fails.
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = CGColor.clear
            window.contentView?.layer?.isOpaque = false
        }

        // ── 2. NSThemeFrame chrome layers ────────────────────────────────────
        // The NSThemeFrame (superview of contentView) and any sibling views
        // macOS injects alongside the hosting view can carry opaque CALayers.
        // Walk every view in that layer — skipping the hosting view itself,
        // which SwiftUI manages — and force their layers clear.
        if let frameView = window.contentView?.superview {
            frameView.wantsLayer = true
            frameView.layer?.backgroundColor = CGColor.clear
            frameView.layer?.isOpaque = false
            for sub in frameView.subviews where sub !== window.contentView {
                sub.wantsLayer = true
                sub.layer?.backgroundColor = CGColor.clear
                sub.layer?.isOpaque = false
            }
        }

        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        // Re-class the SwiftUI-created NSWindow instance to a subclass that
        // overrides canBecomeKey / canBecomeMain → true. Stock NSWindow with
        // styleMask == [.borderless] returns canBecomeKey = false by default
        // (Apple's documented behavior), which means clicks on the window
        // while the app is in the background fail to activate the app.
        //
        // CRITICAL: this MUST run AFTER setStyleMask. setStyleMask triggers
        // SwiftUI's NSHostingView.viewWillMove(toWindow:) cleanup, which
        // calls removeObserver:forKeyPath: on the window. KVO bookkeeping is
        // class-keyed; swapping the class BEFORE setStyleMask makes the
        // observer table un-findable and crashes with
        //   "Cannot remove an observer … is not registered as an observer".
        // After all window mutations are complete, no further code path on
        // our side triggers a KVO cleanup, so the swap is safe.
        object_setClass(window, KeyableBorderlessWindow.self)
    }

    // MARK: - Quit-during-recording alert

    private func presentRecordingInProgressAlert() {
        let alert = NSAlert()
        alert.window.appearance = NSAppearance(named: .darkAqua)
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

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        } catch {
            // M10: log rather than silently skip — if the Desktop is
            // inaccessible (permission revoked, sandboxed), the user
            // should be able to diagnose it from the unified log.
            logger.error("Crash recovery scan failed: \(error.localizedDescription, privacy: .public)")
            return
        }

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
        centerModal(window)

        model.onFinished = { [weak window] in
            NSApp.stopModal()
            window?.orderOut(nil)
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
    }

    // MARK: - Modal placement

    /// Centre `window` on the same screen as the main window, falling back to
    /// the primary screen if neither can be determined. `NSWindow.center()`
    /// always targets the primary screen, which is wrong on multi-monitor rigs
    /// where the user runs DoublEnder on a secondary display (m17).
    private func centerModal(_ window: NSWindow) {
        let screen = mainWindow?.screen ?? NSScreen.main
        guard let screen else { window.center(); return }
        let sf = screen.visibleFrame
        let wf = window.frame
        window.setFrameOrigin(NSPoint(
            x: sf.midX - wf.width / 2,
            y: sf.midY - wf.height / 2
        ))
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

// MARK: - Main window class (key-capable borderless)

/// SwiftUI's WindowGroup creates a stock NSWindow. After we set its style
/// mask to [.borderless] in AppDelegate, the AppKit default for
/// canBecomeKey returns false — which means clicks on the window while the
/// app is backgrounded fail to activate it. AppDelegate `object_setClass`-es
/// the SwiftUI-created instance to this subclass so the OS reads
/// canBecomeKey = true and click-to-activate works from any state.
final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
