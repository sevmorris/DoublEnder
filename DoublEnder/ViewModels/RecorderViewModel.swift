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

    @Published var state: AppState = .selectingMic
    @Published var recordingTime: TimeInterval = 0
    @Published var rmsLevel: Float = 0
    @Published var peakLevel: Float = 0
    @Published var clipDetected: Bool = false
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
    /// appended; an empty string falls back to "DoublEnder".
    @Published var filenameBase: String = "" {
        didSet { UserDefaults.standard.set(filenameBase, forKey: Self.filenameBaseKey) }
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
        audioEngine.$rmsLevel.receive(on: DispatchQueue.main).assign(to: &$rmsLevel)
        audioEngine.$peakLevel.receive(on: DispatchQueue.main).assign(to: &$peakLevel)
        audioEngine.$clipDetected.receive(on: DispatchQueue.main).assign(to: &$clipDetected)
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

        requestPermissions()
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if granted {
                    self.audioEngine.refreshDevices()
                    self.audioEngine.start()
                    let saved = UserDefaults.standard.string(forKey: Self.selectedDeviceKey) ?? ""
                    let devices = self.audioEngine.availableInputDevices
                    if devices.contains(where: { $0.uniqueID == saved }) {
                        self.selectedInputDeviceID = saved
                    } else if let first = devices.first {
                        self.selectedInputDeviceID = first.uniqueID
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
                #if GCS_ENABLED
                // The file is finalized on disk. Hand off to the uploader and
                // let the .uploading state drive the progress UI. The stop
                // button unblocks immediately via the completion call below.
                self.recordingTime = 0
                self.uploadProgress = 0
                self.state = .uploading
                Task { await self.performUpload() }
                #else
                Task { await NotificationService.shared.postRecordingSaved(fileURL: url) }
                self.recordingTime = 0
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

    /// Directory recordings are written to. Shared with AppDelegate's
    /// crash-recovery scan so the two never disagree on where to look.
    static var recordingsDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }

    private func makeRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let prefix = filenameBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = prefix.isEmpty ? "DoublEnder" : prefix
        let filename = "\(base)_\(formatter.string(from: Date())).\(outputFormat.fileExtension)"
        return Self.recordingsDirectory.appendingPathComponent(filename)
    }

    #if GCS_ENABLED
    private func performUpload() async {
        guard let fileURL = recordedFileURL else {
            await MainActor.run { self.state = .error("No recording found to upload") }
            return
        }

        let contentType = outputFormat == .wav ? "audio/wav" : "audio/mp4"

        do {
            try await uploader.upload(fileURL: fileURL, contentType: contentType)
            await MainActor.run {
                Task { await NotificationService.shared.postRecordingSaved(fileURL: fileURL) }
                self.recordingTime = 0
                self.state = .ready
            }
        } catch {
            await MainActor.run {
                self.state = .error("Upload failed: \(error.localizedDescription)")
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
