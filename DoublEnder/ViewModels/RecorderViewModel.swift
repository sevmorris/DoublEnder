import Foundation
import Combine
import AVFoundation
import AppKit
import OSLog

private let logger = Logger(subsystem: "io.github.sevmorris.DoublEnder", category: "RecorderViewModel")

/// Outcome of the pre-recording prompt. Not an optional String: see
/// `RecorderViewModel.requestAutoRecordStart` for why that shape was wrong.
enum AutoRecordDecision {
    /// Start now, optionally under this name.
    case start(name: String?)
    /// Not this session.
    case decline
}

enum AppState {
    case selectingMic
    case ready
    case recording
    #if GCS_ENABLED
    case uploading
    /// Terminal upload failure after automatic retries were exhausted.
    /// Carries the saved local file so the user can retry just the upload.
    case uploadFailed(URL)
    #endif
    case error(String)
}

/// User-selectable output format. The picker in the settings popover binds
/// to this; AudioEngine consumes it when starting a recording.
enum OutputFormat: String, CaseIterable, Identifiable {
    case aac
    case wav

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .aac: return "m4a"
        case .wav: return "wav"
        }
    }

    var displayName: String {
        switch self {
        case .aac: return "AAC / M4A (256 kbps)"
        case .wav: return "WAV (Uncompressed)"
        }
    }
}

class RecorderViewModel: ObservableObject {
    /// Shared instance — AppDelegate needs access for quit-intercept and
    /// crash-recovery, and we want a single source of truth across the
    /// content view and the menubar commands.
    static let shared = RecorderViewModel()

    private static let filenameBaseKey = "filenameBase"
    private static let outputFormatKey = "outputFormat"
    private static let autoRecordEnabledKey = "autoRecordEnabled"
    private static let autoRecordGuestNameKey = "autoRecordGuestName"
    private static let autoRecordNoticeShownKey = "autoRecordNoticeShown"
    /// UID → first-seen timestamp (seconds since 1970) for every USB device
    /// the app has ever observed. Used at launch to break ties when multiple
    /// USB devices are present — the device with the most recent timestamp
    /// wins, capturing "I just plugged this in" intent. Entries are never
    /// pruned (UIDs are stable per physical device, so the map is bounded
    /// by the user's actual hardware history).
    private static let usbFirstSeenKey = "usbDeviceFirstSeenAt"
    #if GCS_ENABLED
    /// Path of a recording whose upload is pending or has failed. Survives
    /// quit so the next launch can offer to finish it.
    private static let pendingUploadKey = "pendingUploadURL"
    /// Legacy key: 2.1.0 persisted the cloud on/off preference here. Cloud is
    /// now always on at launch and the switch is session-scoped, so this key is
    /// never read — only removed, to clear it from installs that set it.
    private static let legacyCloudEnabledKey = "cloudUploadEnabled"
    #endif

    @Published var state: AppState = .selectingMic
    @Published var recordingTime: TimeInterval = 0
    /// Current input level in dBFS (peak-hold), forwarded from AudioEngine for the viewport meter.
    @Published var meterLevel: Float = LevelMeter.dbFloor
    /// True when buffers are actively being appended to the writer.
    /// Drives the on-screen write-flow indicator dot. Forwarded from
    /// AudioEngine.isWritingData.
    @Published var isWritingData: Bool = false

    /// Localized device name shown below the meter. Derived from
    /// `selectedInputDeviceID` (user intent — completely reliable text from
    /// AVCaptureDevice.localizedName) gated on `audioEngine.engineHealthy`
    /// (the engine reached .start without throwing). When the engine
    /// failed to bind / had no usable format / threw during connect, the
    /// label shows "(no input)" so the user knows their pick didn't take.
    ///
    /// Computed rather than stored because there is no single AudioEngine
    /// event that can reliably produce a name string — several rebuild paths
    /// exit early without ever reaching a "publish a name" line. Driving the
    /// label from intent + health makes it impossible for any code path to
    /// leave the label stale: any change to `selectedInputDeviceID`,
    /// `availableInputDevices`, or `audioEngine.engineHealthy` triggers
    /// `objectWillChange` and the view re-evaluates this property.
    var boundInputDeviceName: String? {
        guard let device = audioEngine.availableInputDevices
            .first(where: { $0.uniqueID == selectedInputDeviceID })
        else {
            return nil  // SwiftUI shows "—" via the ?? fallback
        }
        // Two independent reasons the label shows "(no input)":
        //   1. The picked device has no input streams — setDevice rejected
        //      it pre-switch so the session was never rebuilt for it. The
        //      previously-bound device is still active.
        //   2. The engine itself failed to build/start (rebuild error path).
        if !audioEngine.selectedDeviceUsable { return "(no input)" }
        return audioEngine.engineHealthy ? device.localizedName : "(no input)"
    }
    #if GCS_ENABLED
    @Published var uploadProgress: Double = 0
    #endif

    @Published var selectedInputDeviceID: String = "" {
        didSet {
            if isCurrentlyRecording {
                if suppressDeviceSelectionRevert { return }
                if selectedInputDeviceID != oldValue {
                    suppressDeviceSelectionRevert = true
                    selectedInputDeviceID = oldValue
                    suppressDeviceSelectionRevert = false
                }
                return
            }
            audioEngine.clearStaleRecordingSessionIfNeeded()
            if let device = availableInputDevices.first(where: { $0.uniqueID == selectedInputDeviceID }) {
                audioEngine.setDevice(device)
            }
            restartAutoRecordCountdownIfArmed()
        }
    }

    // MARK: - Settings (driven by the gear popover)

    /// Optional override for the filename prefix. The timestamp is always
    /// appended; an empty string falls back to `defaultRecordingPrefix`.
    @Published var filenameBase: String = "" {
        didSet { UserDefaults.standard.set(filenameBase, forKey: Self.filenameBaseKey) }
    }

    /// Default filename prefix used when `filenameBase` is empty. Read from
    /// the bundle's `DefaultRecordingPrefix` Info.plist key (set per target
    /// via the `DEFAULT_RECORDING_PREFIX` build setting). Falls back to
    /// "DoublEnder" for any build that doesn't supply the key.
    static var defaultRecordingPrefix: String {
        guard let value = Bundle.main.infoDictionary?["DefaultRecordingPrefix"] as? String,
              !value.isEmpty else {
            return "DoublEnder"
        }
        return value
    }

    /// Whether the record button should present a pre-recording name prompt
    /// before starting. Cloud sets `REQUIRE_RECORDING_NAME_AT_START` to YES
    /// in project.cloud.yml. Public DoublEnder doesn't declare the Info.plist
    /// key at all, so it reads as falsy here and the prompt code path stays
    /// inert.
    /// True inside an xcodebuild test run, where no human can answer a dialog.
    static var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static var requiresRecordingNameAtStart: Bool {
        guard let raw = Bundle.main.infoDictionary?["RequireRecordingNameAtStart"] as? String else {
            return false
        }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes", "true", "1": return true
        default: return false
        }
    }

    /// Whether the pre-recording name prompt should appear. Cloud builds drop
    /// it when cloud features are off: the prompt exists so the producer can
    /// identify the uploaded object, so with no upload it has no purpose and
    /// local-only mode matches DoublEnder Local exactly (timestamped names,
    /// with the Settings prefix still available).
    var shouldPromptForRecordingName: Bool {
        #if GCS_ENABLED
        return Self.requiresRecordingNameAtStart && cloudUploadEnabled
        #else
        return Self.requiresRecordingNameAtStart
        #endif
    }

    /// Sanitize a user-entered string for use as the entire recording
    /// filename (extension excluded). Caller must check the result for
    /// emptiness — sanitization can produce "" from inputs like "/ / /"
    /// or "...", and an empty string is the signal for the caller to keep
    /// the submit gate closed.
    static func sanitizedRecordingName(from raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = String(String.UnicodeScalarView(
            trimmed.unicodeScalars.map { illegal.contains($0) ? UnicodeScalar("_") : $0 }
        ))
        var collapsed = replaced
        while collapsed.contains("__") {
            collapsed = collapsed.replacingOccurrences(of: "__", with: "_")
        }
        while collapsed.hasPrefix(".") {
            collapsed.removeFirst()
        }
        if collapsed.count > 64 {
            collapsed = String(collapsed.prefix(64))
        }
        return collapsed
    }

    /// Free-form notes written as the file's description metadata tag.
    /// Intentionally not persisted — notes are session-only so stale entries
    /// from a previous session never bleed into a new take.
    @Published var notes: String = ""

    /// Output container/codec. Defaults to AAC.
    @Published var outputFormat: OutputFormat = .aac {
        didSet { UserDefaults.standard.set(outputFormat.rawValue, forKey: Self.outputFormatKey) }
    }

    // MARK: - Auto-record

    /// Persisted, default ON.
    ///
    /// This prompts; it does not record on its own. Capture always begins with
    /// an explicit "Start Recording" — nobody's microphone is opened without
    /// them saying so, which on a guest's own machine is the only defensible
    /// default. What the feature removes is having to *remember* the button:
    /// the dialog comes to you instead of waiting to be found.
    ///
    /// The cost of that choice, stated plainly because it is real: a guest who
    /// walks away from an unanswered prompt records nothing. Consent is worth
    /// more than the guarantee, but the guarantee is genuinely gone.
    ///
    /// Off is remembered across launches — see `cancelAutoRecord()` for the
    /// deliberately session-scoped counterpart.
    @Published var autoRecordEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(autoRecordEnabled, forKey: Self.autoRecordEnabledKey)
            if autoRecordEnabled {
                evaluateAutoRecordArming()
            } else {
                disarmAutoRecord()
            }
        }
    }

    /// Seconds left before auto-record fires, or nil when not counting down.
    /// The faceplate reads this to show the countdown and its cancel control.
    @Published private(set) var autoRecordCountdown: Int?

    /// Cancelled for this launch only. A guest who opened the app to check a
    /// setting means "not right now", not "never" — turning it off for good is
    /// the settings switch, which is a separate, deliberate act.
    private var autoRecordCancelledForLaunch = false

    /// Auto-record fires at most once per launch. Without this, stopping the
    /// auto-started take would re-arm and immediately start another, which is
    /// a trap: you'd have to disable the feature to stop recording at all.
    private var autoRecordFired = false

    private var autoRecordTimer: AnyCancellable?

    /// Remembered across launches and offered back as the prompt's default.
    /// DoublEnder runs on the guest's own machine, so this is "who am I", not
    /// "who is on today" — typed once, correct every session after.
    @Published var autoRecordGuestName: String = "" {
        didSet {
            UserDefaults.standard.set(autoRecordGuestName, forKey: Self.autoRecordGuestNameKey)
        }
    }

    /// Asks the guest whether to start, and under what name. Installed by the
    /// faceplate, which owns the NSAlert; the VM owns *when* it is asked.
    ///
    /// Returns a decision rather than an optional string on purpose. An
    /// optional-returning closure behind an optional hook produced a `String??`
    /// whose two nil layers meant opposite things, and the guard read the wrong
    /// one — declining armed the take, and a missing hook cancelled the feature
    /// outright. An enum makes both cases unrepresentable.
    var requestAutoRecordStart: (() -> AutoRecordDecision)?

    /// Long enough for a USB interface to enumerate and for the switch prompt
    /// to be read and answered, short enough that it doesn't read as hung.
    static let autoRecordCountdownSeconds = 15

    #if GCS_ENABLED
    /// Master switch for every cloud-side feature: GCS upload, the session
    /// heartbeat, the pre-recording name prompt, and the launch-time
    /// pending-upload prompt. Off makes this build behave like DoublEnder
    /// Local — the take still records and saves to the Desktop exactly as
    /// before, it simply never leaves the machine.
    ///
    /// Deliberately session-scoped and NEVER persisted: every launch starts
    /// with cloud ON, so disabling is a conscious act repeated each session.
    /// A guest who switches it off once must not have that silently carry into
    /// a later session — the producer would get no file and no dashboard, with
    /// nothing to explain why. Uploading is the safe default; the burden falls
    /// on turning it off, not on remembering to turn it back on.
    ///
    /// This is a *behaviour* switch, NOT a security boundary. The bundled
    /// service-account key and ingest token ship in this build regardless of
    /// the setting, so a Cloud build stays client-only and must never be
    /// distributed publicly. Only the compile-time `GCS_ENABLED` condition
    /// keeps credentials out of an app.
    @Published var cloudUploadEnabled: Bool = true {
        didSet {
            guard cloudUploadEnabled != oldValue else { return }
            guard !cloudUploadEnabled else { return }
            // Go quiet immediately — a producer watching the dashboard should
            // see this instance stop beating rather than keep reporting idle.
            SessionHeartbeat.shared.deactivate()
            // Never strand the user in a cloud-only terminal state. The file
            // is already safe on the Desktop and the pending-upload record is
            // deliberately preserved for whenever cloud is switched back on.
            if case .uploadFailed = state { state = .ready }
        }
    }
    #endif

    var isCurrentlyRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    #if GCS_ENABLED
    /// True while a finished take's upload is in flight. Read by the
    /// AppDelegate quit intercept (FR-002) so a guest quitting "because
    /// we're done" can't silently kill an upload they don't know is running.
    var isCurrentlyUploading: Bool {
        if case .uploading = state { return true }
        return false
    }
    #endif

    /// True when tapping RECORD will reliably produce a recording.
    /// Gates the RECORD button — STOP during an active recording is
    /// always allowed regardless, so the view should only consult this
    /// when transitioning from idle into recording.
    ///
    /// Combines every engine-side reason recording could be unsafe:
    ///   - The engine hasn't built successfully yet (engineHealthy)
    ///   - The most recent device pick had no input streams and was
    ///     rejected (selectedDeviceUsable) — even if the previous engine
    ///     is still running, starting a recording while the label says
    ///     "(no input)" would mislead the user about what's being captured
    ///   - The engine is mid-rebuild (isRebuilding)
    var canStartRecording: Bool {
        audioEngine.engineHealthy
            && audioEngine.selectedDeviceUsable
            && !audioEngine.isRebuilding
    }

    /// Non-fatal condition worth surfacing in the UI, or nil.
    /// Shown as a compact warning line below the counter in ContentView.
    var recordingWarning: String? {
        // Interruption is the most urgent condition — the session has gone
        // dark and audio may not be flowing. Show it prominently while the
        // watchdog countdown runs.
        if isCurrentlyRecording && audioEngine.sessionInterrupted {
            return "Input interrupted — reconnecting…"
        }
        // SCO / low-quality input: show regardless of recording state so the
        // user can switch devices before pressing record.
        if audioEngine.lowQualityInput { return "Low-quality input (BT SCO?)" }
        // Sidecar failure: only relevant once recording has started.
        if isCurrentlyRecording && audioEngine.sidecarUnavailable { return "No crash recovery" }
        // Sidecar write failure mid-take: backup was running but stopped.
        if isCurrentlyRecording && audioEngine.sidecarFailedDuringRecording { return "Crash backup unavailable" }
        // Dropped frames: at least one buffer was discarded this take.
        if isCurrentlyRecording && audioEngine.droppedFrameWarning { return "Dropped frames — check disk" }
        return nil
    }

    /// UIDs of USB devices the user explicitly dismissed during this app
    /// session ("Keep Current" in the hot-plug prompt). We never re-prompt
    /// for these for the rest of the session. Memory-only — cleared when
    /// the app quits, so a fresh launch will offer again if the device is
    /// still present (or has been re-plugged).
    private var dismissedUSBDevices: Set<String> = []
    /// Prevents re-entrancy when reverting a device pick during recording.
    private var suppressDeviceSelectionRevert = false
    /// True while any app-modal NSAlert runModal() is active. Guards against
    /// a CoreAudio hot-plug callback stacking a second runModal on top of an
    /// open disconnect/idle-loss alert. Set/cleared around every runModal call.
    private var isShowingModalAlert = false

    private let audioEngine = AudioEngine()
    #if GCS_ENABLED
    private let uploader = Uploader()
    #endif
    private var timer: AnyCancellable?
    /// Polls free disk space while a take is in progress so a full volume
    /// triggers a graceful stop before writes start failing.
    private var diskWatchTimer: AnyCancellable?
    /// Polls input health during recording — catches USB unplug before the
    /// device-list listener updates.
    private var inputWatchTimer: AnyCancellable?
    private static let diskWatchInterval: TimeInterval = 5
    private static let inputWatchInterval: TimeInterval = 1
    /// Set when stop was triggered by a disconnect so we can alert the user.
    private var pendingDisconnectReason: String?
    /// Suppresses the idle input-loss alert while a recording-disconnect
    /// handler is already showing one and switching to the built-in mic.
    private var suppressIdleInputLossAlert = false
    /// Prevents back-to-back duplicate disconnect alerts when several
    /// CoreAudio callbacks land in the same unplug event.
    private var lastInputLossAlertAt: Date?
    private static let inputLossAlertCooldown: TimeInterval = 3
    /// True from the start of stopRecording until the engine's completion
    /// fires. Disconnect handler, disk watcher, and user STOP can all call
    /// stopRecording close together — the first call clears the engine's
    /// writer refs, so followers get .noActiveRecording back. This flag lets
    /// us swallow that spurious failure instead of surfacing it as a
    /// "failed to finalize" error to the user.
    private var isFinalizingRecording = false
    private(set) var recordedFileURL: URL?

    var availableInputDevices: [AVCaptureDevice] {
        audioEngine.availableInputDevices
    }

    /// Hardware input devices for the picker. Aggregate / virtual devices
    /// are intentionally excluded.
    var hardwareInputDevices: [AVCaptureDevice] {
        audioEngine.hardwareInputDevices()
    }

    private var cancellables = Set<AnyCancellable>()

    init() {
        audioEngine.$availableInputDevices.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        // Forward engine warning flags so ContentView re-renders when they change.
        audioEngine.$lowQualityInput
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        audioEngine.$sidecarUnavailable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        audioEngine.$sessionInterrupted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        audioEngine.$droppedFrameWarning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        audioEngine.$sidecarFailedDuringRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        audioEngine.$meterLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$meterLevel)
        audioEngine.$isWritingData
            .receive(on: DispatchQueue.main)
            .assign(to: &$isWritingData)
        // engineHealthy and selectedDeviceUsable are read by the computed
        // `boundInputDeviceName`. We don't store their values on the VM —
        // we just need objectWillChange to fire when either changes so
        // SwiftUI re-evaluates the label.
        audioEngine.$engineHealthy
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.evaluateAutoRecordArming()
            }
            .store(in: &cancellables)
        audioEngine.$selectedDeviceUsable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.evaluateAutoRecordArming()
            }
            .store(in: &cancellables)
        // isRebuilding is read by `canStartRecording` — fire objectWillChange
        // when it flips so the RECORD button updates within the same runloop
        // tick that the engine transitions from "in flux" to "ready" (or
        // vice-versa). Without this the button could remain enabled for a
        // tick after a rebuild started.
        audioEngine.$isRebuilding
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                // isRebuilding going false is the usual way canStartRecording
                // first becomes true at launch, so this is the main arming edge.
                self?.evaluateAutoRecordArming()
            }
            .store(in: &cancellables)
        #if GCS_ENABLED
        uploader.$progress.receive(on: DispatchQueue.main).assign(to: &$uploadProgress)
        // Drive the dashboard heartbeat's reported state off the VM state so
        // every exit from .recording (stop, upload, error, disconnect,
        // first-buffer failure) flips it to "idle" — no per-transition hook to
        // keep in sync. Inert until the first recordingStarted().
        $state
            .receive(on: DispatchQueue.main)
            .sink { newState in
                if case .recording = newState {
                    SessionHeartbeat.shared.recordingStateChanged(isRecording: true)
                } else {
                    SessionHeartbeat.shared.recordingStateChanged(isRecording: false)
                }
            }
            .store(in: &cancellables)
        #endif

        audioEngine.$lastError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self else { return }
                self.timer?.cancel()
                self.diskWatchTimer?.cancel()
                if self.isCurrentlyRecording {
                    self.stopRecording()
                } else {
                    self.audioEngine.clearStaleRecordingSessionIfNeeded()
                    self.state = .error(message)
                }
            }
            .store(in: &cancellables)

        // Restore persisted settings. `cloudUploadEnabled` is deliberately
        // absent here — it is session-scoped and always starts ON.
        filenameBase = UserDefaults.standard.string(forKey: Self.filenameBaseKey) ?? ""
        // Absent key means a fresh install, which must default ON — so read the
        // object and only treat an explicit stored false as off.
        if let stored = UserDefaults.standard.object(forKey: Self.autoRecordEnabledKey) as? Bool {
            autoRecordEnabled = stored
        }
        autoRecordGuestName = UserDefaults.standard.string(forKey: Self.autoRecordGuestNameKey) ?? ""
        if let raw = UserDefaults.standard.string(forKey: Self.outputFormatKey),
           let format = OutputFormat(rawValue: raw) {
            outputFormat = format
        }

        // C3 / M1 / M2: When the audio device disconnects mid-recording,
        // AudioEngine signals us here (on the main thread) instead of running
        // its own stop path. This ensures the full VM stop — timer cancel,
        // "recording saved" notification, Cloud upload — all happen correctly.
        // After the stop we also rebuild the engine (M1) and re-validate the
        // selected device (M2) so the app is ready for the next take without
        // requiring the user to re-pick a device.
        audioEngine.onDisconnectedDuringRecording = { [weak self] reason in
            guard let self else { return }
            self.suppressIdleInputLossAlert = true
            self.pendingDisconnectReason = reason
            self.stopRecording {
                self.presentDisconnectAlert(reason: reason)
                self.switchToFallbackInputAfterLoss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.suppressIdleInputLossAlert = false
                }
            }
        }

        audioEngine.onActiveInputLostWhileIdle = { [weak self] in
            guard let self else { return }
            guard !self.suppressIdleInputLossAlert else { return }
            self.switchToFallbackInputAfterLoss()
            self.presentInputLostWhileIdleAlert()
        }

        // USB hot-plug: AudioEngine fires this on the main thread when a new
        // USB input device appears while the app is running. We offer to
        // switch unless recording (don't interrupt), it's already the
        // selected device, or the user dismissed it this session.
        audioEngine.onNewUSBDeviceDetected = { [weak self] device in
            // Reset regardless of what they choose: dismissing the prompt is
            // still a decision made against a running clock, and the whole
            // point of the window is to let device selection settle first.
            self?.restartAutoRecordCountdownIfArmed()
            self?.presentUSBSwitchPrompt(for: device)
        }

        requestPermissions()
    }

    /// App-modal NSAlert offering to switch input to a newly-arrived USB
    /// device. Bails silently for any guard miss so callers can fire this
    /// unconditionally from the engine-side detection.
    private func presentUSBSwitchPrompt(for device: AVCaptureDevice) {
        // NSAlert MUST be driven from the main thread or button clicks
        // never reach the response handler. CoreAudio listener already
        // dispatches to DispatchQueue.main, but defend against any future
        // caller that doesn't.
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.presentUSBSwitchPrompt(for: device)
            }
            return
        }

        // Don't interrupt a take in progress — the new device shows up in
        // the picker dropdown immediately and the user can switch manually
        // after stopping. (Per spec: "If currently recording, do nothing".)
        if isCurrentlyRecording { return }
        // Already the current input — nothing to switch to.
        if device.uniqueID == selectedInputDeviceID { return }
        // User said "Keep Current" for this device earlier this session.
        if dismissedUSBDevices.contains(device.uniqueID) { return }
        // Another alert is already on screen — the device will still appear
        // in the picker; the user can switch manually after dismissing.
        if isShowingModalAlert { return }

        // Refresh first-seen tracking so this device is timestamped — any
        // future launch with multiple USB devices will weight this one as
        // the most recent under Task 3's tie-break.
        recordCurrentUSBDevicesFirstSeen()

        let alert = NSAlert()
        alert.window.appearance = NSAppearance(named: .darkAqua)
        alert.alertStyle = .informational
        alert.messageText = "USB mic detected: \(device.localizedName)"
        alert.informativeText = "Switch input to this device?"
        alert.addButton(withTitle: "Switch")            // .alertFirstButtonReturn
        alert.addButton(withTitle: "Keep Current")      // .alertSecondButtonReturn

        // App-modal runModal() rather than beginSheetModal(for:) — the
        // DoublEnder main window is borderless ([.borderless] styleMask in
        // AppDelegate.configureMainWindow) and AppKit's sheet machinery
        // expects a titled parent to route button-click events to the
        // response handler. On a borderless parent the sheet renders but
        // never delivers clicks, leaving the alert visible but unresponsive
        // (force-quit only). runModal() spins its own nested event loop
        // independent of the parent window's style.
        isShowingModalAlert = true
        let response = alert.runModal()
        isShowingModalAlert = false
        if response == .alertFirstButtonReturn {
            // Defer to the next runloop tick so we're not running engine
            // teardown from inside the CoreAudio device-list listener's
            // call frame (which previously crashed via NSException out of
            // SetOutputFormat).
            let uid = device.uniqueID
            DispatchQueue.main.async { [weak self] in
                self?.selectedInputDeviceID = uid
            }
        } else {
            dismissedUSBDevices.insert(device.uniqueID)
        }
    }

    /// First hardware mic (built-in, USB, Bluetooth) in discovery order, or
    /// nil if none are present. Used wherever the app needs to pick a sensible
    /// default without user input. Virtual / aggregate devices are never
    /// considered — the engine stays stopped instead.
    private func preferredDefaultDevice() -> AVCaptureDevice? {
        audioEngine.hardwareInputDevices().first
    }

    /// Stamp every currently-present USB device that we haven't seen before
    /// with a first-seen timestamp. Idempotent on devices we already know
    /// about. Call this whenever the device list refreshes so the launch-time
    /// tie-break has accurate data for any device the user has ever plugged in.
    func recordCurrentUSBDevicesFirstSeen() {
        var map = UserDefaults.standard.dictionary(forKey: Self.usbFirstSeenKey) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        var changed = false
        for device in audioEngine.usbInputDevices() {
            if map[device.uniqueID] == nil {
                map[device.uniqueID] = now
                changed = true
            }
        }
        if changed {
            UserDefaults.standard.set(map, forKey: Self.usbFirstSeenKey)
        }
    }

    /// USB input device with the most recent first-seen timestamp among
    /// currently-present USB devices. Returns nil if none are present. The
    /// timestamp comes from `recordCurrentUSBDevicesFirstSeen`; devices we've
    /// never stamped fall back to a 0 timestamp, so unknown devices lose
    /// every tie-break to known ones.
    private func mostRecentlyConnectedUSBDevice() -> AVCaptureDevice? {
        let map = UserDefaults.standard.dictionary(forKey: Self.usbFirstSeenKey) as? [String: Double] ?? [:]
        let usb = audioEngine.usbInputDevices()
        return usb.max { (map[$0.uniqueID] ?? 0) < (map[$1.uniqueID] ?? 0) }
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if granted {
                    self.audioEngine.refreshDevices()
                    self.recordCurrentUSBDevicesFirstSeen()

                    // Deterministic launch: always seed the engine with the
                    // Mac's built-in hardware mic, regardless of any saved
                    // preference or currently-attached USB device. This
                    // gives every launch the same predictable starting
                    // state.
                    //
                    // The post-init USB prompt below offers a one-tap
                    // switch when a USB input is present, so podcast
                    // guests still default to the mic they expect — they
                    // just confirm the switch explicitly rather than have
                    // it happen silently from saved state.
                    if let builtIn = self.audioEngine.builtInInputDevice() {
                        self.selectedInputDeviceID = builtIn.uniqueID
                    } else if let fallback = self.preferredDefaultDevice() {
                        // No built-in mic on this Mac (Mac mini, Mac
                        // Studio, etc.). Fall back to the first hardware
                        // input so we still have an engine running when
                        // the USB prompt fires below.
                        self.selectedInputDeviceID = fallback.uniqueID
                    } else {
                        // No input devices at all — engine stays stopped;
                        // user will see the normal "no device" state.
                        self.audioEngine.start()
                    }
                    self.state = .ready

                    // Post-init USB offer: if a USB input is currently
                    // present, fire the same prompt the hot-plug detector
                    // uses. AudioEngine.refreshDevices seeds its known-UID
                    // set on its first call, so `onNewUSBDeviceDetected`
                    // does NOT fire for launch-time USBs — we drive the
                    // prompt from here explicitly. Most-recent-first-seen
                    // wins when multiple USBs are present, capturing
                    // "the one I just plugged in" intent across launches.
                    if let usbDevice = self.mostRecentlyConnectedUSBDevice() {
                        self.presentUSBSwitchPrompt(for: usbDevice)
                    }
                } else {
                    self.state = .error("Microphone access denied. Go to System Settings → Privacy & Security → Microphone and enable DoublEnder.")
                }
            }
        }
        // Best-effort notification permission request alongside the mic prompt.
        Task { await NotificationService.shared.requestAuthorization() }
    }

    /// `nameOverride`, when non-nil and non-empty after sanitization, is
    /// used as the entire filename (no timestamp). Cloud builds with the
    /// pre-recording name prompt pass the user's input here; other callers
    /// omit the argument and fall through to the timestamp scheme.
    // MARK: - Auto-record

    /// Arm the countdown if every precondition holds. Cheap and idempotent —
    /// call it from anything that could make auto-record newly possible.
    private func evaluateAutoRecordArming() {
        // A test host launches the real app, so anything that presents UI at
        // launch blocks xcodebuild forever with nobody to answer it. That is
        // not hypothetical: this prompt hung DoublEnderCloudTests, and with it
        // verify-cloud.sh and release-cloud.sh, until the run was killed.
        guard !Self.isRunningUnderTests else { return }

        guard autoRecordEnabled,
              !autoRecordCancelledForLaunch,
              !autoRecordFired,
              !isCurrentlyRecording,
              autoRecordTimer == nil,
              canStartRecording,
              // No point counting down to a prompt that cannot be shown; a
              // later arming edge picks this up once the faceplate is up.
              requestAutoRecordStart != nil
        else { return }

        // Once, on the first launch that can arm. An existing install would
        // otherwise get an unexplained dialog fifteen seconds after opening,
        // which reads as the app doing something behind your back — the exact
        // impression a recorder can least afford to give.
        presentAutoRecordNoticeIfNeeded()
        guard autoRecordEnabled else { return }   // they chose Turn Off in it

        startAutoRecordCountdown()
    }

    /// Blocking by design: it runs before the countdown starts, so the clock
    /// cannot expire behind it. Suppressed under tests with everything else.
    private func presentAutoRecordNoticeIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.autoRecordNoticeShownKey) else { return }
        // Marked shown BEFORE presenting, deliberately. If the app dies while
        // the alert is up, the choice is between never showing it again and
        // showing it every launch forever; a dialog that cannot be escaped is
        // the worse of the two.
        UserDefaults.standard.set(true, forKey: Self.autoRecordNoticeShownKey)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "DoublEnder now offers to start recording"
        alert.informativeText = """
            \(Self.autoRecordCountdownSeconds) seconds after the app is ready,             DoublEnder asks whether to start, so a session can't be missed.

            Recording never begins until you say so, and you can change this             any time under Settings.
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Turn Off")
        if alert.runModal() == .alertSecondButtonReturn {
            autoRecordEnabled = false
        }
    }

    private func startAutoRecordCountdown() {
        autoRecordCountdown = Self.autoRecordCountdownSeconds
        // .common, so the clock keeps running behind a modal. .default would
        // pause it, which sounds safer and is not: an unanswered dialog would
        // suspend auto-record indefinitely, and "nobody is at the keyboard" is
        // exactly the case this feature exists for. The USB switch prompt gets
        // its window back through restartAutoRecordCountdownIfArmed() instead
        // — an explicit reset for the one dialog whose outcome changes the take.
        autoRecordTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.autoRecordTick() }
    }

    private func autoRecordTick() {
        guard let remaining = autoRecordCountdown else { return }
        guard canStartRecording else {
            // The engine went out from under us (device rebuild, disconnect).
            // Stand down rather than fire into a session that can't capture;
            // whatever restores the engine re-arms through evaluate.
            disarmAutoRecord()
            return
        }
        if remaining > 1 {
            autoRecordCountdown = remaining - 1
            return
        }
        disarmAutoRecord()
        autoRecordFired = true
        askToStartRecording()
    }

    /// The settle window is over and the mic has stopped moving — ask.
    /// Declining is a session-scoped no, exactly like cancelling the countdown.
    private func askToStartRecording() {
        guard let ask = requestAutoRecordStart else { return }
        switch ask() {
        case .decline:
            autoRecordCancelledForLaunch = true
        case .start(let name):
            if let name, !name.isEmpty { autoRecordGuestName = name }
            startRecording(nameOverride: name)
        }
    }

    /// A new input device appeared, or the selection changed. Give the guest
    /// the full window back — they were almost certainly mid-setup, and the
    /// device they end on is the one they're stuck with for the whole take.
    private func restartAutoRecordCountdownIfArmed() {
        guard autoRecordTimer != nil else { return }
        autoRecordCountdown = Self.autoRecordCountdownSeconds
    }

    /// Stop the countdown without deciding anything about future arming.
    private func disarmAutoRecord() {
        autoRecordTimer?.cancel()
        autoRecordTimer = nil
        autoRecordCountdown = nil
    }

    /// The guest declined this one. Stays declined until the app is relaunched.
    func cancelAutoRecord() {
        autoRecordCancelledForLaunch = true
        disarmAutoRecord()
    }

    func startRecording(nameOverride: String? = nil) {
        if let reason = DiskSpaceChecker.recordingBlockedReason(
            for: Self.recordingsDirectory,
            format: outputFormat
        ) {
            state = .error(reason)
            return
        }
        // Covers both callers: a manual RECORD tap that beat the countdown,
        // and the countdown firing. Either way nothing should stay armed.
        disarmAutoRecord()
        autoRecordFired = true

        do {
            let fileURL = makeRecordingURL(nameOverride: nameOverride)

            // Crash recovery is keyed off the PCM sidecar file, which the
            // audio engine creates the moment the writer starts — no
            // separate UserDefaults flag to keep in sync.
            try audioEngine.startRecording(to: fileURL, format: outputFormat, notes: notes)

            recordedFileURL = fileURL
            state = .recording
            #if GCS_ENABLED
            // Start/refresh the dashboard heartbeat for this take. Fire-and-
            // forget; a dead dashboard never affects capture. The $state sink
            // (see init) flips it to "idle" on every exit from .recording.
            // Skipped entirely in local-only mode — the heartbeat stays inert
            // because it only ever activates from recordingStarted().
            if cloudUploadEnabled {
                SessionHeartbeat.shared.recordingStarted(guestName: nameOverride)
            }
            #endif
            recordingTime = 0
            timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                self?.recordingTime += 1
            }
            diskWatchTimer = Timer.publish(every: Self.diskWatchInterval, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.checkDiskSpaceDuringRecording() }
            inputWatchTimer = Timer.publish(every: Self.inputWatchInterval, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.audioEngine.checkRecordingInputHealth() }
        } catch {
            state = .error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    /// Stop the take when the Desktop volume drops below the minimum —
    /// finalize while the writer can still flush rather than failing mid-stream.
    private func checkDiskSpaceDuringRecording() {
        guard isCurrentlyRecording else { return }
        guard DiskSpaceChecker.recordingBlockedReason(
            for: Self.recordingsDirectory,
            format: outputFormat
        ) != nil else {
            return
        }
        stopRecording()
    }

    /// Cleanly finalize the current recording. `completion` runs on the main
    /// queue once the writer has closed the file (or failed).
    func stopRecording(completion: (() -> Void)? = nil) {
        // Snapshot before flipping so we can tell apart "first call into the
        // engine" from "a follower racing the first one". `isFinalizingRecording`
        // is cleared only when finalization completes (success or real failure).
        let alreadyFinalizing = isFinalizingRecording
        isFinalizingRecording = true
        timer?.cancel()
        diskWatchTimer?.cancel()
        inputWatchTimer?.cancel()

        audioEngine.stopRecording { [weak self] result in
            guard let self = self else {
                completion?()
                return
            }
            // A follower call into the engine after the first one already
            // cleared its writer refs — engine returned noActiveRecording but
            // the file is being saved by the first call's path. Surfacing an
            // error here would be a lie. Leave the in-flight flag set; the
            // originating call will clear it.
            if alreadyFinalizing,
               case .failure(let error) = result,
               let recError = error as? RecordingError,
               case .noActiveRecording = recError {
                completion?()
                return
            }
            self.isFinalizingRecording = false
            switch result {
            case .success(.some(let url)):
                // Notify the user that the recording is on disk — fires for both
                // DoublEnder and DoublEnderCloud so every saved file gets a
                // system notification with a Reveal in Finder action, regardless
                // of whether an upload follows.
                Task { await NotificationService.shared.postRecordingSaved(fileURL: url) }
                #if GCS_ENABLED
                guard self.cloudUploadEnabled else {
                    // Local-only mode: identical to the non-GCS path below —
                    // the take is saved and confirmed, and nothing is uploaded.
                    self.recordingTime = 0
                    self.recordedFileURL = nil
                    self.state = .ready
                    RecordingSavedConfirmation.present(fileName: url.lastPathComponent)
                    self.pendingDisconnectReason = nil
                    completion?()
                    return
                }
                // The file is finalized on disk. Hand off to the uploader and
                // let the .uploading state drive the progress UI. The stop
                // button unblocks immediately via the completion call below.
                self.recordingTime = 0
                self.uploadProgress = 0
                self.state = .uploading
                Task { await self.performUpload() }
                #else
                self.recordingTime = 0
                self.recordedFileURL = nil  // m10: clear stale reference after save
                self.state = .ready
                RecordingSavedConfirmation.present(fileName: url.lastPathComponent)
                self.pendingDisconnectReason = nil
                completion?()
                return
                #endif
            case .success(.none):
                self.recordingTime = 0
                self.recordedFileURL = nil
                if let reason = self.pendingDisconnectReason {
                    self.state = .error(
                        "\(reason). No audio was captured — try again with the built-in microphone."
                    )
                } else {
                    self.state = .ready
                }
            case .failure(let error):
                self.recordingTime = 0
                if self.recoverSidecarIfNeeded(from: self.recordedFileURL) {
                    self.recordedFileURL = nil
                    self.state = .ready
                } else if self.hasRecoverableSidecar(for: self.recordedFileURL) {
                    self.state = .error(
                        "Recording was interrupted but your audio is safe. "
                            + "Quit and relaunch DoublEnder to recover it as a WAV file."
                    )
                } else {
                    let prefix = self.pendingDisconnectReason.map { "\($0). " } ?? ""
                    self.state = .error("\(prefix)Failed to finalize recording: \(error.localizedDescription)")
                }
            }
            self.pendingDisconnectReason = nil
            completion?()
        }
    }

    /// Re-wrap a `.pcmrec` sidecar into a WAV when the main writer could not
    /// finalize — returns true when a recovered file was saved and presented.
    private func recoverSidecarIfNeeded(from mainOutput: URL?) -> Bool {
        guard let mainOutput else { return false }
        let sidecarURL = PCMSidecar.url(for: mainOutput)
        guard PCMSidecar.hasRecoverableContent(at: sidecarURL) else { return false }
        do {
            let recovered = try PCMSidecar.recoverToWAV(sidecarURL: sidecarURL)
            try? FileManager.default.removeItem(at: sidecarURL)
            try? FileManager.default.removeItem(at: mainOutput)
            Task { await NotificationService.shared.postRecordingSaved(fileURL: recovered) }
            #if GCS_ENABLED
            // Local-only mode mirrors the Local build's confirmation; with
            // cloud on, the upload flow owns the user-facing confirmation.
            if !cloudUploadEnabled {
                RecordingSavedConfirmation.present(fileName: recovered.lastPathComponent)
            }
            #else
            RecordingSavedConfirmation.present(fileName: recovered.lastPathComponent)
            #endif
            return true
        } catch {
            logger.error("Sidecar recovery failed: \(error.localizedDescription, privacy: .public)")
            state = .error("The recording couldn't be recovered: \(error.localizedDescription). The recovery file is still on disk — check disk space and permissions, then relaunch to retry.")
            return false
        }
    }

    private func switchToFallbackInputAfterLoss() {
        audioEngine.refreshDevices()
        if let builtIn = audioEngine.builtInInputDevice() {
            selectedInputDeviceID = builtIn.uniqueID
        } else if let fallback = preferredDefaultDevice() {
            selectedInputDeviceID = fallback.uniqueID
        } else {
            audioEngine.start()
        }
    }

    private func presentDisconnectAlert(reason: String) {
        guard shouldPresentInputLossAlert() else { return }
        guard !isShowingModalAlert else { return }
        let alert = NSAlert()
        alert.window.appearance = NSAppearance(named: .darkAqua)
        alert.alertStyle = .warning
        alert.messageText = "Microphone disconnected"
        alert.informativeText = "\(reason). Your recording has been stopped and saved if possible. Switched to the built-in microphone."
        alert.addButton(withTitle: "OK")
        isShowingModalAlert = true
        alert.runModal()
        isShowingModalAlert = false
    }

    private func presentInputLostWhileIdleAlert() {
        guard shouldPresentInputLossAlert() else { return }
        guard !isShowingModalAlert else { return }
        let alert = NSAlert()
        alert.window.appearance = NSAppearance(named: .darkAqua)
        alert.alertStyle = .warning
        alert.messageText = "Microphone disconnected"
        alert.informativeText = "The selected input is no longer available. Switched to the built-in microphone."
        alert.addButton(withTitle: "OK")
        isShowingModalAlert = true
        alert.runModal()
        isShowingModalAlert = false
    }

    private func shouldPresentInputLossAlert() -> Bool {
        let now = Date()
        if let last = lastInputLossAlertAt,
           now.timeIntervalSince(last) < Self.inputLossAlertCooldown {
            return false
        }
        lastInputLossAlertAt = now
        return true
    }

    /// Abort the current recording without finalizing — used by the
    /// "Quit Without Saving" path. The partial file and its recovery
    /// sidecar are both deleted so a future launch doesn't surface them.
    func abortRecording(completion: (() -> Void)? = nil) {
        timer?.cancel()
        diskWatchTimer?.cancel()
        inputWatchTimer?.cancel()
        pendingDisconnectReason = nil
        let url = recordedFileURL

        audioEngine.cancelRecording { [weak self] in
            if let url = url {
                try? FileManager.default.removeItem(at: url)
            }
            self?.recordingTime = 0
            self?.recordedFileURL = nil
            // No state mutation needed — the app is about to terminate.
            completion?()
        }
    }

    /// Clear session-scoped settings on clean app termination so the next
    /// launch starts fresh with the default DoublEnder_<timestamp> pattern.
    /// Called from AppDelegate.applicationWillTerminate. Sticky settings
    /// (output format, selected mic) are intentionally preserved. The notes
    /// field isn't persisted, so nothing to clear there.
    ///
    /// We hit UserDefaults directly rather than mutating `filenameBase` —
    /// that property's didSet would re-write the key with an empty string.
    func clearSessionSettings() {
        UserDefaults.standard.removeObject(forKey: Self.filenameBaseKey)
    }

    /// Called from `applicationWillFinishLaunching` — before the VM is
    /// initialised — so that a crash or force-quit in a prior session doesn't
    /// leave a stale custom filename in UserDefaults for the next launch.
    static func eraseSessionDefaults() {
        UserDefaults.standard.removeObject(forKey: filenameBaseKey)
        #if GCS_ENABLED
        // One-time cleanup of the 2.1.0 persisted cloud preference. Cloud is
        // always on at launch now, so a stored value must not linger and must
        // never be honoured.
        UserDefaults.standard.removeObject(forKey: legacyCloudEnabledKey)
        #endif
    }

    /// Directory recordings are written to. Shared with AppDelegate's
    /// crash-recovery scan so the two never disagree on where to look.
    static var recordingsDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }

    private func makeRecordingURL(nameOverride: String? = nil) -> URL {
        let ext = outputFormat.fileExtension
        let dir = Self.recordingsDirectory

        // Name-prompt path: the user-entered name *is* the filename.
        // No timestamp. Collisions get _2, _3, … so a guest recorded twice
        // doesn't clobber the first take.
        if let override = nameOverride,
           !Self.sanitizedRecordingName(from: override).isEmpty {
            let stem = Self.sanitizedRecordingName(from: override)
            var candidate = dir.appendingPathComponent("\(stem).\(ext)")
            var n = 2
            while FileManager.default.fileExists(atPath: candidate.path) {
                candidate = dir.appendingPathComponent("\(stem)_\(n).\(ext)")
                n += 1
            }
            return candidate
        }

        let formatter = DateFormatter()
        // POSIX locale prevents locale-specific characters (am/pm, RTL
        // markers, non-Gregorian calendars) from appearing in filenames.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Millisecond precision shrinks the same-timestamp collision window
        // from 1 second to 1 ms — effectively impossible in practice.
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let prefix = filenameBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = prefix.isEmpty ? Self.defaultRecordingPrefix : prefix
        let timestamp = formatter.string(from: Date())

        // De-duplicate defensively: if two recordings land on the exact same
        // millisecond (or a stale file already exists), append _2, _3, …
        var candidate = dir.appendingPathComponent("\(base)_\(timestamp).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)_\(timestamp)_\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    #if GCS_ENABLED
    /// A recording whose upload is pending or has failed, persisted across quit
    /// so the next launch can finish it. `sessionURI`/`crc32c` are set once a
    /// resumable session has been initiated: with them, a resume continues from
    /// GCS's committed offset instead of restarting; without them (a crash
    /// before initiation, or a legacy record) the upload restarts (FR-003).
    private struct PendingUpload: Codable {
        let path: String
        var sessionURI: String?
        var crc32c: String?
    }

    /// The persisted pending upload, or nil. Tolerates a legacy bare-path value
    /// written by a pre-FR-003 build (treated as "no session → restart").
    private var persistedPendingUpload: PendingUpload? {
        guard let raw = UserDefaults.standard.string(forKey: Self.pendingUploadKey) else { return nil }
        if let data = raw.data(using: .utf8),
           let record = try? JSONDecoder().decode(PendingUpload.self, from: data) {
            return record
        }
        return PendingUpload(path: raw, sessionURI: nil, crc32c: nil)
    }

    /// Path of a recording whose upload is pending/failed, if any. Read by
    /// AppDelegate at launch to offer to finish an interrupted upload.
    var persistedPendingUploadPath: String? { persistedPendingUpload?.path }

    /// Persist (or update) the pending-upload record.
    private func setPendingUpload(_ record: PendingUpload) {
        guard let data = try? JSONEncoder().encode(record),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: Self.pendingUploadKey)
    }

    /// Forget the pending upload (called on success, or when the user skips
    /// the launch prompt).
    func clearPendingUpload() {
        UserDefaults.standard.removeObject(forKey: Self.pendingUploadKey)
    }

    /// Manual retry from the upload-failed error view. The local file is
    /// untouched — re-attempt only the upload, no new recording.
    func retryUpload() {
        guard cloudUploadEnabled else { return }
        guard recordedFileURL != nil else {
            state = .error("No recording found to upload")
            return
        }
        uploadProgress = 0
        state = .uploading
        Task { await performUpload() }
    }

    /// Resume an upload the previous session left pending (launch prompt).
    func resumePendingUpload(fileURL: URL) {
        guard cloudUploadEnabled else { return }
        recordedFileURL = fileURL
        uploadProgress = 0
        state = .uploading
        Task { await performUpload() }
    }

    /// Category + HTTP status distilled from an upload failure, for diagnostics
    /// logging (FR-004). Deliberately excludes the GCS response body (which can
    /// echo the object path / service-account email) and never touches the
    /// signed URL or key material — only a fixed category label and the numeric
    /// status reach the log.
    private static func uploadErrorSummary(_ error: Error) -> (label: String, status: Int?) {
        if let ue = error as? Uploader.UploaderError {
            switch ue {
            case .server(let status, _): return ("server", status)
            case .missingKeyFile:        return ("missingKeyFile", nil)
            case .malformedKeyFile:      return ("malformedKeyFile", nil)
            case .invalidPrivateKey:     return ("invalidPrivateKey", nil)
            case .signingFailed:         return ("signingFailed", nil)
            case .integrityMismatch:     return ("integrity-mismatch", nil)
            case .integrityUnverified:   return ("integrity-unverified", nil)
            }
        }
        if let urlError = error as? URLError {
            return ("network:\(urlError.code.rawValue)", nil)
        }
        if error is CancellationError {
            return ("cancelled", nil)
        }
        return ("other", nil)
    }

    /// True when a failed upload's HTTP status is in the request-validity
    /// failure class where a badly-skewed client clock is a plausible cause.
    /// Confirmed against the GCS XML API status reference: a clock that fell
    /// behind yields 400 (`ExpiredToken`); a clock that ran ahead yields 403
    /// (`RequestTimeTooSkewed`) — and 403 also covers `SignatureDoesNotMatch`.
    /// 5xx and network errors are excluded so the clock hint never fires when
    /// the clock is fine.
    private static func statusSuggestsClockSkew(_ status: Int?) -> Bool {
        status == 400 || status == 403
    }

    /// Upload the saved local file via a resumable session, retrying with
    /// exponential backoff (2s, 4s, 8s). Each retry RESUMES from GCS's committed
    /// offset rather than restarting (FR-003). The pending record is persisted
    /// up front (path only) so an interruption before initiation still restarts
    /// next launch, then upgraded with the session URI so an interruption after
    /// initiation resumes.
    private func performUpload() async {
        guard let fileURL = recordedFileURL else {
            await MainActor.run { self.state = .error("No recording found to upload") }
            return
        }

        // Preserve the pre-initiation restart guarantee: if no resumable session
        // exists yet, record the path now so a crash before init still leaves
        // something for the next-launch prompt.
        if persistedPendingUpload?.sessionURI == nil {
            setPendingUpload(PendingUpload(path: fileURL.path, sessionURI: nil, crc32c: nil))
        }

        let backoffSeconds: [UInt64] = [2, 4, 8]   // before retries 1, 2, 3
        var attempt = 0

        while true {
            await MainActor.run { self.state = .uploading }
            let attemptStart = Date()
            do {
                // Establish or resume the resumable session. Once initiated, the
                // session URI + CRC32C are persisted so a later attempt (this
                // loop or a relaunch) resumes from GCS's committed offset.
                let sessionURI: URL
                let crc: String
                if let record = persistedPendingUpload,
                   let uriString = record.sessionURI,
                   let uri = URL(string: uriString),
                   let storedCRC = record.crc32c {
                    sessionURI = uri
                    crc = storedCRC
                } else {
                    let began = try await uploader.beginUpload(fileURL: fileURL)
                    sessionURI = began.sessionURI
                    crc = began.crc32c
                    setPendingUpload(PendingUpload(path: fileURL.path,
                                                   sessionURI: sessionURI.absoluteString,
                                                   crc32c: crc))
                }

                try await uploader.continueUpload(fileURL: fileURL,
                                                  sessionURI: sessionURI,
                                                  crc32cBase64: crc)

                self.clearPendingUpload()
                await MainActor.run {
                    self.recordingTime = 0
                    self.state = .ready
                    // Persistent, app-controlled confirmation — blocks until
                    // the user clicks OK (notifications can't guarantee this).
                    UploadConfirmation.present(success: true,
                                               fileName: fileURL.lastPathComponent)
                }
                return
            } catch {
                // Diagnostics (FR-004): log a sanitized summary only — HTTP
                // status, error category, attempt number, backoff, elapsed —
                // never the signed URL, session URI, key material, response
                // body, or any file path / guest name.
                let summary = Self.uploadErrorSummary(error)
                let statusText = summary.status.map(String.init) ?? "—"
                let elapsedText = String(format: "%.1fs", Date().timeIntervalSince(attemptStart))
                // Deterministic failures (integrity mismatch, credential/signing)
                // won't fix by re-sending — fail now, keep the local file.
                let nonRetryable = (error as? Uploader.UploaderError)?.isNonRetryable ?? false
                guard !nonRetryable, attempt < backoffSeconds.count else {
                    logger.error("Upload failed after \(attempt + 1, privacy: .public) attempt(s): \(summary.label, privacy: .public), status \(statusText, privacy: .public), \(elapsedText, privacy: .public). Recording kept on Desktop; pending upload persisted for next launch.")
                    if Self.statusSuggestsClockSkew(summary.status) {
                        logger.error("Upload rejected with HTTP \(statusText, privacy: .public). If this keeps happening, a common cause is the Mac's date & time being off by more than ~15 minutes — check System Settings › General › Date & Time.")
                    }
                    await MainActor.run {
                        self.state = .uploadFailed(fileURL)
                        UploadConfirmation.present(success: false,
                                                   fileName: fileURL.lastPathComponent)
                    }
                    return
                }
                let delay = backoffSeconds[attempt]
                logger.warning("Upload attempt \(attempt + 1, privacy: .public) failed: \(summary.label, privacy: .public), status \(statusText, privacy: .public), \(elapsedText, privacy: .public). Resuming in \(delay, privacy: .public)s.")
                attempt += 1
                // Stay in .uploading across the backoff so the UI shows a
                // resume in progress rather than a flash of failure.
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
    }
    #endif

    func reset() {
        timer?.cancel()
        diskWatchTimer?.cancel()
        inputWatchTimer?.cancel()
        pendingDisconnectReason = nil
        if audioEngine.isRecordingActive {
            audioEngine.abandonStaleRecordingState()
        }
        finishReset()
    }

    private func finishReset() {
        audioEngine.clearStaleRecordingSessionIfNeeded()
        audioEngine.clearLastError()
        state = .ready
        recordingTime = 0
        #if GCS_ENABLED
        uploadProgress = 0
        #endif
        recordedFileURL = nil
        audioEngine.start()
    }

    /// True when a `.pcmrec` sidecar exists for the given main output URL,
    /// meaning launch-time recovery can re-wrap the take into a WAV.
    private func hasRecoverableSidecar(for mainOutput: URL?) -> Bool {
        guard let mainOutput else { return false }
        return FileManager.default.fileExists(atPath: PCMSidecar.url(for: mainOutput).path)
    }
}

extension TimeInterval {
    var hhmmss: String {
        let total = Int(self)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
