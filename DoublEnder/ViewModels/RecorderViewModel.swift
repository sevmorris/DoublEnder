import Foundation
import Combine
import AVFoundation
import AppKit

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

    private static let selectedDeviceKey = "selectedInputDeviceID"
    private static let filenameBaseKey = "filenameBase"
    private static let outputFormatKey = "outputFormat"
    #if GCS_ENABLED
    /// Path of a recording whose upload is pending or has failed. Survives
    /// quit so the next launch can offer to finish it.
    private static let pendingUploadKey = "pendingUploadURL"
    #endif

    @Published var state: AppState = .selectingMic
    @Published var recordingTime: TimeInterval = 0
    /// Current input level in dBFS (-60…0), forwarded from AudioEngine.
    /// Used by the viewport level meter; resets to -60 when recording stops.
    @Published var rmsLevel: Float = -60
    #if GCS_ENABLED
    @Published var uploadProgress: Double = 0
    #endif

    @Published var selectedInputDeviceID: String = "" {
        didSet {
            UserDefaults.standard.set(selectedInputDeviceID, forKey: Self.selectedDeviceKey)
            if let device = availableInputDevices.first(where: { $0.uniqueID == selectedInputDeviceID }) {
                audioEngine.setDevice(device)
            }
        }
    }

    // MARK: - Settings (driven by the gear popover)

    /// Optional override for the filename prefix. The timestamp is always
    /// appended; an empty string falls back to `defaultRecordingPrefix`.
    @Published var filenameBase: String = "" {
        didSet { UserDefaults.standard.set(filenameBase, forKey: Self.filenameBaseKey) }
    }

    /// Default filename prefix used when `filenameBase` is empty. Read from
    /// the bundle's `DefaultRecordingPrefix` Info.plist key so branded Cloud
    /// builds can ship with a per-client default (set via the
    /// `DEFAULT_RECORDING_PREFIX` xcodebuild override in
    /// release-cloud-branded.sh). Falls back to "DoublEnder" for any build
    /// that doesn't supply the key.
    static var defaultRecordingPrefix: String {
        guard let value = Bundle.main.infoDictionary?["DefaultRecordingPrefix"] as? String,
              !value.isEmpty else {
            return "DoublEnder"
        }
        return value
    }

    /// Free-form notes written as the file's description metadata tag.
    /// Intentionally not persisted — notes are session-only so stale entries
    /// from a previous session never bleed into a new take.
    @Published var notes: String = ""

    /// Output container/codec. Defaults to AAC.
    @Published var outputFormat: OutputFormat = .aac {
        didSet { UserDefaults.standard.set(outputFormat.rawValue, forKey: Self.outputFormatKey) }
    }

    var isCurrentlyRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    /// Non-fatal condition worth surfacing in the UI, or nil.
    /// Shown as a compact warning line below the counter in ContentView.
    var recordingWarning: String? {
        // SCO / low-quality input: show regardless of recording state so the
        // user can switch devices before pressing record.
        if audioEngine.lowQualityInput { return "Low-quality input (BT SCO?)" }
        // Sidecar failure: only relevant once recording has started.
        if isCurrentlyRecording && audioEngine.sidecarUnavailable { return "No crash recovery" }
        return nil
    }

    private let audioEngine = AudioEngine()
    #if GCS_ENABLED
    private let uploader = Uploader()
    #endif
    private var timer: AnyCancellable?
    private(set) var recordedFileURL: URL?

    var availableInputDevices: [AVCaptureDevice] {
        audioEngine.availableInputDevices
    }

    /// Hardware mics vs. aggregate/virtual devices for the grouped picker.
    var inputDeviceGroups: (microphones: [AVCaptureDevice], virtual: [AVCaptureDevice]) {
        audioEngine.groupedInputDevices()
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
        audioEngine.$rmsLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$rmsLevel)
        #if GCS_ENABLED
        uploader.$progress.receive(on: DispatchQueue.main).assign(to: &$uploadProgress)
        #endif

        audioEngine.$lastError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self else { return }
                self.timer?.cancel()
                self.state = .error(message)
            }
            .store(in: &cancellables)

        // Restore persisted settings.
        filenameBase = UserDefaults.standard.string(forKey: Self.filenameBaseKey) ?? ""
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
        audioEngine.onDisconnectedDuringRecording = { [weak self] in
            guard let self else { return }
            self.stopRecording {
                // Rebuild with the best available device.
                self.audioEngine.refreshDevices()
                let devices = self.availableInputDevices
                if let device = devices.first(where: { $0.uniqueID == self.selectedInputDeviceID }) {
                    // M1: selected device is still present — reconnect to it.
                    self.audioEngine.setDevice(device)
                } else if let device = self.preferredDefaultDevice() {
                    // M2: selected device is gone — fall back to the best
                    // available hardware mic. didSet persists the choice and
                    // calls setDevice → rebuildEngine automatically.
                    self.selectedInputDeviceID = device.uniqueID
                }
                // If no input devices are available at all, the engine stays
                // stopped; the user will see the normal "no device" state.
            }
        }

        requestPermissions()
    }

    /// First hardware mic (built-in, USB, Bluetooth) in discovery order,
    /// falling back to the first virtual/aggregate device, then nil.
    /// Used wherever the app needs to pick a sensible default without user input.
    private func preferredDefaultDevice() -> AVCaptureDevice? {
        let groups = audioEngine.groupedInputDevices()
        return groups.microphones.first ?? groups.virtual.first
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if granted {
                    self.audioEngine.refreshDevices()
                    let devices = self.audioEngine.availableInputDevices
                    let saved = UserDefaults.standard.string(forKey: Self.selectedDeviceKey) ?? ""
                    // m7: restore the saved device ID *before* starting the
                    // engine so it builds with the right device directly —
                    // avoids the start-then-immediately-rebuild churn that
                    // happened when the selection was restored afterwards.
                    if devices.contains(where: { $0.uniqueID == saved }) {
                        self.selectedInputDeviceID = saved  // triggers setDevice → rebuildEngine
                    } else if let device = self.preferredDefaultDevice() {
                        // No saved device (or it's gone) — pick the best
                        // hardware mic automatically, avoiding virtual devices.
                        self.selectedInputDeviceID = device.uniqueID
                    } else {
                        // No devices at all — start with system default and
                        // wait for the user to plug something in.
                        self.audioEngine.start()
                    }
                    self.state = .ready
                } else {
                    self.state = .error("Microphone access denied. Go to System Settings → Privacy & Security → Microphone and enable DoublEnder.")
                }
            }
        }
        // Best-effort notification permission request alongside the mic prompt.
        Task { await NotificationService.shared.requestAuthorization() }
    }

    func startRecording() {
        do {
            let fileURL = makeRecordingURL()

            // Crash recovery is keyed off the PCM sidecar file, which the
            // audio engine creates the moment the writer starts — no
            // separate UserDefaults flag to keep in sync.
            try audioEngine.startRecording(to: fileURL, format: outputFormat, notes: notes)

            recordedFileURL = fileURL
            state = .recording
            recordingTime = 0
            timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                self?.recordingTime += 1
            }
        } catch {
            state = .error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    /// Cleanly finalize the current recording. `completion` runs on the main
    /// queue once the writer has closed the file (or failed).
    func stopRecording(completion: (() -> Void)? = nil) {
        timer?.cancel()

        audioEngine.stopRecording { [weak self] result in
            guard let self = self else {
                completion?()
                return
            }
            switch result {
            case .success(let url):
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                guard size > 0 else {
                    self.state = .error("Recording produced an empty file. Check microphone permission and input device.")
                    completion?()
                    return
                }
                // Notify the user that the recording is on disk — fires for both
                // DoublEnder and DoublEnderCloud so every saved file gets a
                // system notification with a Reveal in Finder action, regardless
                // of whether an upload follows.
                Task { await NotificationService.shared.postRecordingSaved(fileURL: url) }
                #if GCS_ENABLED
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
                #endif
            case .failure(let error):
                self.state = .error("Failed to finalize recording: \(error.localizedDescription)")
            }
            completion?()
        }
    }

    /// Abort the current recording without finalizing — used by the
    /// "Quit Without Saving" path. The partial file and its recovery
    /// sidecar are both deleted so a future launch doesn't surface them.
    func abortRecording(completion: (() -> Void)? = nil) {
        timer?.cancel()
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
    }

    /// Directory recordings are written to. Shared with AppDelegate's
    /// crash-recovery scan so the two never disagree on where to look.
    static var recordingsDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }

    private func makeRecordingURL() -> URL {
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
        let ext = outputFormat.fileExtension
        let dir = Self.recordingsDirectory

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
    /// Path of a recording whose upload is pending/failed, if any. Read by
    /// AppDelegate at launch to offer to finish an interrupted upload.
    var persistedPendingUploadPath: String? {
        UserDefaults.standard.string(forKey: Self.pendingUploadKey)
    }

    /// Persist the path of the recording whose upload is in progress.
    /// Using this helper keeps all pendingUploadKey read/write in one place.
    private func setPendingUpload(path: String) {
        UserDefaults.standard.set(path, forKey: Self.pendingUploadKey)
    }

    /// Forget the pending upload (called on success, or when the user skips
    /// the launch prompt).
    func clearPendingUpload() {
        UserDefaults.standard.removeObject(forKey: Self.pendingUploadKey)
    }

    /// Manual retry from the upload-failed error view. The local file is
    /// untouched — re-attempt only the upload, no new recording.
    func retryUpload() {
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
        recordedFileURL = fileURL
        uploadProgress = 0
        state = .uploading
        Task { await performUpload() }
    }

    /// Upload the saved local file, retrying with exponential backoff
    /// (2s, 4s, 8s) before surfacing failure. The recording is already
    /// safe on disk; only the upload is being retried. The pending-upload
    /// path is persisted up front so an interrupted upload survives quit.
    private func performUpload() async {
        guard let fileURL = recordedFileURL else {
            await MainActor.run { self.state = .error("No recording found to upload") }
            return
        }

        let contentType = outputFormat == .wav ? "audio/wav" : "audio/mp4"
        setPendingUpload(path: fileURL.path)

        let backoffSeconds: [UInt64] = [2, 4, 8]   // before retries 1, 2, 3
        var attempt = 0

        while true {
            await MainActor.run {
                self.uploadProgress = 0
                self.state = .uploading
            }
            do {
                try await uploader.upload(fileURL: fileURL, contentType: contentType)
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
                guard attempt < backoffSeconds.count else {
                    // Retries exhausted — surface a distinct, reassuring
                    // failure state. The pending path stays persisted so a
                    // quit-then-relaunch can still offer to finish it.
                    await MainActor.run {
                        self.state = .uploadFailed(fileURL)
                        UploadConfirmation.present(success: false,
                                                   fileName: fileURL.lastPathComponent)
                    }
                    return
                }
                let delay = backoffSeconds[attempt]
                attempt += 1
                // Stay in .uploading across the backoff so the UI shows a
                // retry in progress rather than a flash of failure.
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
    }
    #endif

    func reset() {
        timer?.cancel()
        state = .selectingMic
        recordingTime = 0
        #if GCS_ENABLED
        uploadProgress = 0
        #endif
        recordedFileURL = nil
        audioEngine.start()
    }
}

extension TimeInterval {
    var mmss: String {
        let minutes = Int(self) / 60
        let seconds = Int(self) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var hhmmss: String {
        let total = Int(self)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
