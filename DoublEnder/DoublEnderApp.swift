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
        // An update asking a staged copy whether it starts at all: it does.
        UpdateSelfTest.exitIfAsked()
        if isHostingTests {
            TestHostApp.main()
            return
        }
        processStart = Date()
        executableName = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String
        runningExecutable = Bundle.main.executableURL.flatMap(FileIdentity.init)
        // Before anything else can fail: a version just installed that has
        // started twice without staying up is replaced by the one before it.
        let rollback = UpdateRollback.atLaunch(
            runningVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            installed: Bundle.main.bundleURL, store: .app,
            tools: .live(bundleID: Bundle.main.bundleIdentifier ?? ""))
        if rollback == .rolledBack { exit(0) }
        DoublEnderApp.main()
    }

    /// When this run began, for the sweep of what earlier runs left.
    nonisolated(unsafe) static var processStart = Date.distantPast
    /// The running executable as the file system knew it at launch, so an
    /// update can tell whether the app at its path is still this one.
    nonisolated(unsafe) static var runningExecutable: FileIdentity?
    nonisolated(unsafe) static var executableName: String?

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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: FaceplateWindow?

    /// Setup that must come before SwiftUI's launch pass, ending with the
    /// recorder on screen.
    func applicationWillFinishLaunching(_ notification: Notification) {
        registerBundledFonts()
        NotificationService.shared.configure()
        sweepUpdateLeftovers()
        // m5: clear session-scoped settings (custom filename) before the VM
        // is initialised — this is the only reliable path that also runs after
        // a crash or force-quit, where applicationWillTerminate never fires.
        RecorderViewModel.eraseSessionDefaults()
        // After the erase, because the content view brings up the VM. Before
        // SwiftUI's launch pass, because with no window on screen by then
        // SwiftUI would present the empty Settings scene.
        #if GCS_ENABLED
        // Cloud installs any update before the recorder exists. Its window is
        // what SwiftUI finds on screen meanwhile.
        LaunchUpdate.run { [weak self] checkAfterLaunch in
            guard let self else { return }
            self.showMainWindow()
            self.checkForUpdatesAfterLaunch = checkAfterLaunch
            self.launchUpdateDone = true
            if self.didFinishLaunching { self.startUp() }
        }
        #else
        showMainWindow()
        #endif
    }

    #if GCS_ENABLED
    /// The recorder is open, the launch update having installed nothing.
    private var launchUpdateDone = false
    /// applicationDidFinishLaunching has come, which may be before or after that.
    private var didFinishLaunching = false
    /// Whether the usual check after launch still has something to offer.
    private var checkForUpdatesAfterLaunch = true
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if GCS_ENABLED
        // Crash recovery and pending uploads wait for the recorder, and are
        // the new version's to handle when an update relaunches the app.
        didFinishLaunching = true
        guard launchUpdateDone else { return }
        #endif
        startUp()
    }

    private func startUp() {
        #if GCS_ENABLED
        let recovered = runCrashRecoveryIfNeeded()
        offerWaitingUploads(recovered: recovered)
        // A launch install that ran out of time or failed, or a check that
        // did, is finished behind the recorder and installed at quit, rather
        // than offered in a prompt the guest has to answer. Only what this copy
        // cannot install by itself is still offered.
        if checkForUpdatesAfterLaunch {
            UpdateCoordinator.shared.startBackgroundUpdate(promptIfStuck: true)
        }
        scheduleUpdatesWhileOpen()
        #else
        runCrashRecoveryIfNeeded()
        Task { await checkForUpdates(silent: true) }
        #endif
    }

    #if GCS_ENABLED
    private var updateTimer: Timer?

    /// A guest who leaves the app open for days is updated too: every few
    /// hours, and soon after a wake, a check runs while nothing is under way,
    /// and what it finds is installed when the app quits.
    private func scheduleUpdatesWhileOpen() {
        let timer = Timer(timeInterval: BackgroundUpdateSchedule.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.considerUpdateWhileOpen(afterWake: false) }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                MainRunLoop.perform(after: BackgroundUpdateSchedule.afterWake) {
                    self?.considerUpdateWhileOpen(afterWake: true)
                }
            }
        }
    }

    private func considerUpdateWhileOpen(afterWake: Bool) {
        let coordinator = UpdateCoordinator.shared
        guard BackgroundUpdateSchedule.isDue(now: Date(), lastCheck: coordinator.lastCheck, afterWake: afterWake),
              !AppActivity.shared.blocksHeavyWork else { return }
        coordinator.startBackgroundUpdate(promptIfStuck: false)
    }
    #endif

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
        // A clean quit is as healthy as a few seconds of recorder: a guest who
        // quits at once must not count against the version. Before the recorder
        // has opened the version has shown nothing either way, so the start is
        // simply not counted.
        if mainWindow != nil {
            Self.markUpdateHealthy()
        } else {
            UpdateRollback.noteCleanQuitBeforeHealthy(runningVersion: Self.runningVersion,
                                                      installed: Bundle.main.bundleURL, store: .app)
        }
        // A copy staged behind the recorder is installed now, and the next
        // launch runs it. Anything else staged goes with the app.
        UpdateCoordinator.shared.installAtQuit()
        UpdateCoordinator.shared.cleanUpForQuit()
        // Without a recorder there are no session settings beyond what
        // applicationWillFinishLaunching already erased.
        guard mainWindow != nil else { return }
        RecorderViewModel.shared.clearSessionSettings()
        // synchronize() has been a documented no-op since macOS 10.12 —
        // the OS flushes UserDefaults automatically. Removed (m6).
    }

    /// Quit intercept: if recording, surface the save/discard/cancel choice
    /// before allowing termination. On Cloud builds, an in-flight upload gets
    /// its own keep-uploading/quit-anyway intercept (FR-002) — the states are
    /// mutually exclusive, so at most one alert presents.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Read now: the quit event is the current Apple event only while this runs.
        quitIsForSystem = QuitDuringTake.isSystemQuit(reason: Self.currentQuitReason())
        return quitReply()
    }

    /// The Mac is logging out, restarting or shutting down: the app goes, as
    /// asked, whatever it would otherwise stay open for.
    private var quitIsForSystem = false

    /// Why the quit event in hand was sent, when the system says.
    private static func currentQuitReason() -> OSType? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
                ?? event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)) else { return nil }
        return reason.typeCodeValue != 0 ? reason.typeCodeValue : reason.enumCodeValue
    }

    private func quitReply() -> NSApplication.TerminateReply {
        // What there is to ask about comes from AppActivity, which an update
        // reads too: it only replaces the app when there is nothing, so its
        // quit never meets a question. With no recorder yet (Cloud's launch
        // update relaunching, or ⌘Q during it) there is nothing to ask, and
        // AppActivity does not build the recorder to find out.
        switch AppActivity.shared.quitQuestion {
        case .recording:
            presentRecordingInProgressAlert()
            return .terminateLater
        case .uploading:
            #if GCS_ENABLED
            presentUploadInProgressAlert()
            return .terminateLater
            #else
            return .terminateNow
            #endif
        case nil:
            // A download or a copy under way stops first, so the disk image is
            // not left mounted and the copy not left behind.
            if UpdateCoordinator.shared.cancelBeforeQuit(then: { NSApp.reply(toApplicationShouldTerminate: true) }) {
                return .terminateLater
            }
            return .terminateNow
        }
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
        // The recorder exists from here on, so its takes and uploads count.
        AppActivity.shared.recorder = { RecorderViewModel.shared.activityBlockers }
        // AppKit lists only titled windows in the Window menu by itself.
        NSApp.addWindowsItem(window, title: window.title, filename: false)
        window.makeKeyAndOrderFront(nil)
        // A version just installed has shown it can stay up once its
        // recorder has been on screen a few seconds; the one before it goes.
        MainRunLoop.perform(after: Self.healthyAfter) { Self.markUpdateHealthy() }
    }

    /// How long the recorder stays up before a new version counts as healthy.
    private static let healthyAfter: TimeInterval = 5

    private static var runningVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private static func markUpdateHealthy() {
        UpdateRollback.markHealthy(runningVersion: runningVersion, installed: Bundle.main.bundleURL,
                                   store: .app, discard: { SelfUpdater.discard($0) })
    }

    /// What an update cut short in an earlier run: a mounted image, a download,
    /// a staged copy. Taken off the journal here, before this run can stage
    /// anything; the detaching and deleting happen off the main thread.
    private func sweepUpdateLeftovers() {
        let holders = UpdateSweep.takeLeftovers(store: .app)
        let start = AppLauncher.processStart
        let temporary = FileManager.default.temporaryDirectory
        DispatchQueue.global(qos: .utility).async {
            UpdateSweep.sweep(holders: holders, temporaryDirectory: temporary, processStart: start)
        }
    }

    // MARK: - Quit-during-recording alert

    private func presentRecordingInProgressAlert() {
        let alert = NSAlert()
        alert.window.appearance = NSAppearance(named: .darkAqua)
        alert.alertStyle = .warning
        alert.messageText = "Recording in progress"
        let vm = RecorderViewModel.shared
        #if GCS_ENABLED
        let staysToUpload = vm.cloudUploadEnabled && !quitIsForSystem
        #else
        let staysToUpload = false
        #endif
        alert.informativeText = QuitDuringTake.message(appName: updaterAppName, staysToUpload: staysToUpload)
        alert.addButton(withTitle: "Stop & Save")           // .alertFirstButtonReturn
        alert.addButton(withTitle: "Quit Without Saving")   // .alertSecondButtonReturn
        alert.addButton(withTitle: "Cancel")                // .alertThirdButtonReturn

        let response = ModalGate.run { alert.runModal() }
        let forSystem = quitIsForSystem

        switch QuitDuringTake.action(for: response,
                                     takeInProgress: AppActivity.shared.quitQuestion == .recording) {
        case .stopThenQuit:
            // Finalize the writer, then continue termination once the file
            // is closed — unless the take is now uploading (Cloud), which the
            // app stays open for.
            vm.stopRecording { [weak self] in
                let uploading = AppActivity.shared.quitQuestion == .uploading
                let quits = QuitDuringTake.quitsAfterStop(uploading: uploading, forSystem: forSystem)
                if !quits {
                    // In front, so the guest sees why it is still open. It
                    // quits once the upload is through and the guest has seen
                    // it go; quitting again asks about the upload.
                    #if GCS_ENABLED
                    vm.quitWhenUploaded = true
                    #endif
                    NSApp.activate(ignoringOtherApps: true)
                    self?.mainWindow?.makeKeyAndOrderFront(nil)
                }
                NSApp.reply(toApplicationShouldTerminate: quits)
            }
        case .discardThenQuit:
            // Cancel the writer and drop the partial file before quitting.
            vm.abortRecording {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        case .stay:
            NSApp.reply(toApplicationShouldTerminate: false)
        case .askAgain:
            // The take the question was about is over. The quit goes on from
            // what the app is doing now: an upload gets its own question.
            if quitReply() == .terminateNow {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
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

        let response = ModalGate.run { alert.runModal() }
        NSApp.reply(toApplicationShouldTerminate: response != .alertFirstButtonReturn)
    }
    #endif

    // MARK: - Crash recovery

    /// A PCM sidecar on disk means a previous recording never finalized —
    /// the matching .m4a (if any) is unplayable. Present a themed dialog
    /// per sidecar that re-wraps it into a valid WAV off the main thread.
    /// Returns the WAVs the user recovered.
    @discardableResult
    private func runCrashRecoveryIfNeeded() -> [URL] {
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
            ModalGate.run { alert.runModal() }
            return []
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
        guard !recoverable.isEmpty else { return [] }

        // Recovery is a gate the user must clear before using the app — keep
        // the main recorder window hidden until every sidecar is resolved,
        // then bring it forward. Untouched when no recovery is needed, so
        // the normal launch path has no flicker.
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.orderOut(nil)
        let recovered = recoverable.compactMap { presentRecoveryDialog(for: $0) }
        mainWindow?.makeKeyAndOrderFront(nil)
        return recovered
    }

    #if GCS_ENABLED
    /// One question at launch for every take still to be uploaded: uploads an
    /// earlier run left unfinished, takes put off with LATER or with SKIP last
    /// time, and takes crash recovery has just put back together (their session
    /// ended before an upload could start). UPLOAD sends them one after
    /// another. SKIP keeps them: they are offered again at the next launch, and
    /// do not upload by themselves before it. SKIP used to forget an
    /// interrupted upload for good, and a recovered take was never offered
    /// again; a take is now forgotten only when its file is gone.
    private func offerWaitingUploads(recovered: [URL]) {
        let vm = RecorderViewModel.shared
        // Local-only mode: say nothing, and keep everything for when cloud is
        // switched back on.
        guard vm.cloudUploadEnabled else { return }
        for take in recovered where FileManager.default.fileExists(atPath: take.path) {
            vm.waitToUpload(take)
        }
        let waiting = vm.takesWaitingToUpload()
        guard let first = waiting.first else { return }

        mainWindow?.orderOut(nil)
        let upload = PendingUploadPrompt.present(fileName: first.lastPathComponent, count: waiting.count)
        mainWindow?.makeKeyAndOrderFront(nil)

        if upload {
            vm.uploadWaitingTakes()
        } else {
            vm.putOffWaitingTakesUntilNextLaunch()
        }
    }
    #endif

    /// Runs a modal session for one sidecar. The modal run loop keeps the
    /// window — and its spinner — responsive while `RecoveryModel` does the
    /// conversion on a background queue. Returns the recovered WAV, if the
    /// user recovered one.
    private func presentRecoveryDialog(for sidecar: URL) -> URL? {
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

        ModalGate.run {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.runModal(for: window)
        }

        if case .success(let url) = model.phase { return url }
        return nil
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
        for name in ["DSEG7Classic-Regular", "Saira-Regular"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

// MARK: - Quit during a take

/// What to do with the answer to "Recording in progress".
///
/// The take can end while the question is up: the producer stops it from the
/// dashboard, the microphone is unplugged, the disk fills, or a stop already
/// under way closes the file. The answer is then about a take that no longer
/// exists. "Stop & Save" used to run a second stop, which found nothing, put
/// "No audio was captured" on the faceplate and quit over the upload that had
/// just begun; "Quit Without Saving" deleted the file that had just been saved.
enum QuitDuringTake {
    enum Action: Equatable {
        case stopThenQuit
        case discardThenQuit
        /// Cancel: the app stays open.
        case stay
        /// Nothing left to stop or discard: decide the quit afresh.
        case askAgain
    }

    /// The question's text. In Cloud with upload on, Stop & Save no longer
    /// quits: the take uploads, and the app stays open for it.
    static func message(appName: String, staysToUpload: Bool) -> String {
        if staysToUpload {
            return "Stop & Save saves what has been recorded so far, and \(appName) stays open to upload it, "
                + "then quits. Quitting without saving will lose the current recording."
        }
        return "Stopping now will save what has been recorded so far. "
            + "Quitting without saving will lose the current recording."
    }

    /// After Stop & Save has closed the file: whether the quit goes ahead now.
    ///
    /// Cloud's upload starts the moment the file is closed, and the app used to
    /// quit right then, so the take waited on the Desktop for the next launch
    /// to offer it, which may be days, while the producer waited for it. The
    /// app now stays open and uploads, and quits once the guest has seen the
    /// upload succeed (`RecorderViewModel.quitWhenUploaded`). A failed upload
    /// keeps it open. Quitting again asks about the upload, whose Quit Anyway
    /// quits at once: nothing can hold a quit for ever.
    /// A logout, restart or shutdown still goes ahead, as the system asked:
    /// the take is recorded as pending and the next launch offers it.
    static func quitsAfterStop(uploading: Bool, forSystem: Bool) -> Bool {
        !uploading || forSystem
    }

    /// The reasons the system gives when it quits apps for a logout, a restart
    /// or a shutdown (`kAEQuitReason`). A quit the person asked for has none.
    static func isSystemQuit(reason: OSType?) -> Bool {
        guard let reason else { return false }
        let system: Set<OSType> = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog,
                                   kAERestart, kAEShutDown, kAEQuitAll]
        return system.contains(reason)
    }

    /// `response` is nil when the question could not open (an update is
    /// replacing the app).
    static func action(for response: NSApplication.ModalResponse?, takeInProgress: Bool) -> Action {
        switch response {
        case .alertFirstButtonReturn?:
            return takeInProgress ? .stopThenQuit : .askAgain
        case .alertSecondButtonReturn?:
            return takeInProgress ? .discardThenQuit : .askAgain
        default:
            return .stay
        }
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
