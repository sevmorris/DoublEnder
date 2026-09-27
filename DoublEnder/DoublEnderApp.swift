import SwiftUI
import AppKit
import CoreText
import OSLog

private let logger = Logger(subsystem: "io.github.sevmorris.DoublEnder", category: "AppDelegate")

/// Decides, before anything else runs, whether this launch is the app or only
/// the host for the unit tests.
///
/// Xcode runs the tests inside this app, so a test run used to launch all of
/// it: the app delegate erased the session defaults in the app's real domain,
/// scanned for crashed recordings and checked for updates; the window built
/// the recorder, which asked for the microphone, migrated the guest name and
/// stamped every connected USB device into those defaults; and SwiftUI
/// recorded the window's frame. Hosting tests, the app now starts with no
/// window, no app delegate and no recorder.
@main
enum AppLauncher {
    static func main() {
        if isHostingTests {
            TestHostApp.main()
        } else {
            DoublEnderApp.main()
        }
    }

    /// XCTest is already loaded when main() runs in a test host, and is never
    /// linked into the app itself. The session identifier is Xcode's own mark
    /// of a test launch, checked as well in case XCTest ever loads later.
    static let isHostingTests =
        NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
}

/// A scene with no window: while the app hosts the tests, nothing of the real
/// app is built.
private struct TestHostApp: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}

extension UserDefaults {
    /// Where the app keeps what it stores in defaults. It is the app's own
    /// domain — except in a test run, where `.standard` is that same domain,
    /// the developer's real settings, because the tests run inside the app.
    /// A test run gets a scratch suite in its place, so a test that forgets
    /// to pass a store of its own still cannot reach the real one. Nothing in
    /// the app names `.standard`; it goes through here.
    ///
    /// The scratch suite is named by a path in the temporary folder, which
    /// keeps its file out of ~/Library/Preferences, where the App Preferences
    /// source's io.github.sevmorris.* pattern would back it up. It carries the
    /// bundle identifier, so the Local and Cloud builds' test runs stay apart.
    static let app: UserDefaults = AppLauncher.isHostingTests
        ? UserDefaults(suiteName: FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "io.github.sevmorris.DoublEnder").tests").path)!
        : .standard
}

struct DoublEnderApp: App {
    // The recorder window is AppDelegate's own (FaceplateWindow), along with
    // the quit intercept and crash recovery. SwiftUI keeps the Help window
    // and the menus.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // SwiftUI presents an app's first scene at launch when no window is
        // on screen by then — on macOS 26 even a Settings scene. AppDelegate
        // has the recorder on screen before that point, so nothing is
        // presented. This empty scene is first so that Help never is, and
        // it carries the menus.
        Settings { EmptyView() }
        .commands {
            // There is no settings window, so no Settings… (⌘,) item.
            CommandGroup(replacing: .appSettings) {}

            // With no WindowGroup, SwiftUI builds no File menu and nothing
            // answers ⌘W. Close goes to the key window: Help closes, and the
            // recorder asks to quit (FaceplateWindow.performClose).
            CommandGroup(replacing: .saveItem) {
                Button("Close") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w")
            }

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

                #if GCS_ENABLED
                // Cloud users are typically podcast guests recording for a
                // specific producer — but the free Local recorder is a useful
                // fallback for any other recording they need to do. Point them
                // to the landing page so they can grab it.
                Button("Get DoublEnder (Local Recorder)") {
                    if let url = URL(string: "https://sevmorris.github.io/DoublEnder/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                #else
                Button("Support on Ko-fi") {
                    if let url = URL(string: "https://ko-fi.com/sevmo") {
                        NSWorkspace.shared.open(url)
                    }
                }
                #endif

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
    private var mainWindow: FaceplateWindow?

    /// Setup that must come before SwiftUI's launch pass, ending with the
    /// recorder on screen.
    func applicationWillFinishLaunching(_ notification: Notification) {
        registerBundledFonts()
        NotificationService.shared.configure()
        // m5: clear session-scoped settings (custom filename) before the VM
        // is initialised — this is the only reliable path that also runs after
        // a crash or force-quit, where applicationWillTerminate never fires.
        RecorderViewModel.eraseSessionDefaults()
        // After the erase, because the content view brings up the VM. Before
        // SwiftUI's launch pass, because with no window on screen by then
        // SwiftUI would present the empty Settings scene.
        showMainWindow()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        runCrashRecoveryIfNeeded()
        #if GCS_ENABLED
        runPendingUploadCheckIfNeeded()
        #endif
        Task { await checkForUpdates(silent: true) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // The recorder can become key, so AppKit restores the key window on
        // activation by itself. Reclaim focus only if nothing has it: doing
        // it every time would take key from Help whenever the app is
        // activated with Help in front.
        if NSApp.keyWindow == nil {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    /// A Dock click with nothing on screen brings the recorder back —
    /// except while a launch prompt is keeping it hidden. Answering false
    /// keeps SwiftUI from presenting a scene of its own.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && NSApp.modalWindow == nil {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
        return false
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
    /// before allowing termination. On Cloud builds, an in-flight upload gets
    /// its own keep-uploading/quit-anyway intercept (FR-002) — the states are
    /// mutually exclusive, so at most one alert presents.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if RecorderViewModel.shared.isCurrentlyRecording {
            presentRecordingInProgressAlert()
            return .terminateLater
        }
        #if GCS_ENABLED
        if RecorderViewModel.shared.isCurrentlyUploading {
            presentUploadInProgressAlert()
            return .terminateLater
        }
        #endif
        return .terminateNow
    }

    /// ⌘W on the recorder routes through here (FaceplateWindow.performClose).
    /// We re-route to `terminate` so there's a single quit confirmation path.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    // MARK: - Main window

    private func showMainWindow() {
        #if GCS_ENABLED
        let window = FaceplateWindow(rootView: CloudContentView())
        #else
        let window = FaceplateWindow(rootView: ContentView())
        #endif
        window.delegate = self
        mainWindow = window
        // AppKit lists only titled windows in the Window menu by itself.
        NSApp.addWindowsItem(window, title: window.title, filename: false)
        window.makeKeyAndOrderFront(nil)
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

    #if GCS_ENABLED
    /// Quit intercept for an in-flight upload (FR-002). Two choices, both
    /// resolving termination immediately — there is deliberately NO
    /// "wait for the upload to finish" path, so a stalled upload can never
    /// hang quit. The recording is already safe on the Desktop, and the
    /// pending-upload path was persisted before the PUT began, so quitting
    /// only defers the upload to the next-launch prompt.
    private func presentUploadInProgressAlert() {
        let alert = NSAlert()
        alert.window.appearance = NSAppearance(named: .darkAqua)
        alert.alertStyle = .warning
        alert.messageText = "Upload in progress"
        alert.informativeText = "Your recording is saved on the Desktop, but it hasn't finished uploading. If you quit now, DoublEnder will offer to finish the upload the next time it opens."
        alert.addButton(withTitle: "Keep Uploading")   // .alertFirstButtonReturn (default: Return keeps the upload alive)
        alert.addButton(withTitle: "Quit Anyway")      // .alertSecondButtonReturn

        let response = alert.runModal()
        NSApp.reply(toApplicationShouldTerminate: response != .alertFirstButtonReturn)
    }
    #endif

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
            // S3: also surface to the user — silently skipping means a
            // recording from a prior crash can sit on Desktop forever
            // with no indication it's there to recover.
            let alert = NSAlert()
            alert.window.appearance = NSAppearance(named: .darkAqua)
            alert.alertStyle = .warning
            alert.messageText = "Couldn't Check for Unsaved Recordings"
            alert.informativeText = "DoublEnder couldn't check the Desktop for recordings from a previous session: \(error.localizedDescription). Check that the Desktop is accessible and relaunch to retry."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let sidecars = entries.filter { $0.pathExtension == PCMSidecar.pathExtension }
        let mainFileValidThreshold = PCMSidecar.mainFileValidThresholdBytes
        for sidecar in sidecars where !PCMSidecar.hasRecoverableContent(at: sidecar) {
            try? fm.removeItem(at: sidecar)
            let mainURL = PCMSidecar.mainOutputURL(for: sidecar)
            let attrs = try? fm.attributesOfItem(atPath: mainURL.path)
            let mainSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if mainSize > mainFileValidThreshold {
                logger.warning("Empty sidecar next to apparently valid main file \(mainURL.lastPathComponent, privacy: .public) (\(mainSize) bytes) — keeping main file")
            } else {
                try? fm.removeItem(at: mainURL)
            }
        }

        let recoverable = sidecars.filter { PCMSidecar.hasRecoverableContent(at: $0) }
        guard !recoverable.isEmpty else { return }

        // Recovery is a gate the user must clear before using the app — keep
        // the main recorder window hidden until every sidecar is resolved,
        // then bring it forward. Untouched when no recovery is needed, so
        // the normal launch path has no flicker.
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.orderOut(nil)
        for sidecar in recoverable {
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
        // Local-only mode: stay silent, but deliberately leave the pending
        // record intact so turning cloud back on still offers to finish it.
        guard vm.cloudUploadEnabled else { return }
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
        window.level = .modalPanel
        centerModal(window)

        model.onFinished = { [weak window] in
            NSApp.stopModal()
            window?.orderOut(nil)
        }

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.runModal(for: window)
    }

    // MARK: - Modal placement

    /// Size `window` to its content and centre it on the same screen as the
    /// main window, falling back to the primary screen if neither can be
    /// determined. `NSWindow.center()` always targets the primary screen,
    /// which is wrong on multi-monitor rigs where the user runs DoublEnder on
    /// a secondary display (m17).
    private func centerModal(_ window: NSWindow) {
        // Taking the hosting controller left the window the size of the
        // controller's view, which SwiftUI hasn't laid out yet: 0×0. It grows
        // to fit only after the first layout, from its bottom-left corner, so
        // centring it as it is put that corner in the middle of the screen.
        if let content = window.contentViewController?.view {
            window.setContentSize(content.fittingSize)
        }
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

// MARK: - Main window

/// The recorder's window: borderless and clear, with the faceplate art as its
/// only frame.
///
/// The app builds it rather than taking SwiftUI's. SwiftUI's window class,
/// `SwiftUI.AppKitWindow`, answers false to `canBecomeKey` once the window is
/// borderless, and so does its `.plain` style — so a click from another app
/// could not activate the recorder and it could not take the keyboard. Up to
/// 2.5.x the app re-classed SwiftUI's window to get round that, which cut the
/// window off from SwiftUI's KVO observers and its own overrides (see
/// THEORY_OF_OPERATION §10). Built here, the window is borderless from its
/// first frame, so there is no chrome to strip either.
final class FaceplateWindow: NSWindow {
    private static let autosaveName = "Faceplate"

    init<Content: View>(rootView: Content) {
        let hostingView = NSHostingView(rootView: rootView)
        super.init(contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        contentView = hostingView
        title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "DoublEnder"
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        // WindowDragArea moves the window; AppKit's background drag stays off
        // (THEORY_OF_OPERATION §10, "Moving the window").
        isMovableByWindowBackground = false
        collectionBehavior = [.primary, .fullScreenNone]
        restoreFrame(swiftUIName: "\(String(reflecting: Content.self))-1-AppWindow-1")
    }

    /// Up to 2.5.x the window was SwiftUI's, which saved its frame under a
    /// name made from the root view's type ("DoublEnder.ContentView-1-AppWindow-1").
    /// That is read once, so the first launch after the update opens where
    /// the last one left off; from then on the frame is saved under our own
    /// name. A window that can't be resized takes only the position from it.
    private func restoreFrame(swiftUIName: String) {
        if !setFrameUsingName(Self.autosaveName) && !setFrameUsingName(swiftUIName) {
            center()
        }
        setFrameAutosaveName(Self.autosaveName)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// AppKit's performClose asks the delegate only when the window has a
    /// close button, and a borderless one has none, so ⌘W would end there.
    override func performClose(_ sender: Any?) {
        if delegate?.windowShouldClose?(self) ?? true {
            close()
        }
    }
}
