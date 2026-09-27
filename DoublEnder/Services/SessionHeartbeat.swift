import Foundation
import CoreAudio
import CoreMedia
import OSLog

// The heartbeat is Cloud-only: compiled into Cloud builds and stripped
// entirely from the public Local build, like the other #if GCS_ENABLED
// surfaces in the shared tree. What it reports about the Mac, the input and
// the take (`SessionDiagnostics`, below it) compiles into every build, so the
// tests hold it to its privacy rules; only the heartbeat sends it.
#if GCS_ENABLED
private let logger = Logger(subsystem: "io.github.sevmorris.DoublEnder", category: "SessionHeartbeat")

/// Fire-and-forget session heartbeat to the dashboard Worker's `/ingest`
/// endpoint. Lets a producer see live sessions as Recording / Idle / Stale.
///
/// Pull-based by design: this instance beats its current state on a fixed
/// cadence; the Worker derives STALE from the *absence* of beats (no heartbeat
/// within its stale window) and TTL-expires a dead instance. So a crash needs
/// no "I died" message — the beats simply stop.
///
/// Reporting model:
///   • recording  → beat "recording" every `intervalSeconds`.
///   • stopped/any non-recording state (while the app stays open) → beat
///     "idle", so a clean stop reads Recording→Idle on the dashboard while a
///     mid-recording crash reads Recording→Stale (beats stop). That distinction
///     is the whole point of the dashboard, so "idle" is sent explicitly rather
///     than letting a still-"recording" beat age to stale.
///
/// Auth is a Cloudflare Access **service token** (CF-Access-Client-Id /
/// CF-Access-Client-Secret) validated by Access at the edge. The id/secret and
/// the ingest URL come from Info.plist keys injected at build time from a
/// gitignored file (see release-cloud-from-local.sh) — never literals in
/// source. When any is absent/empty (dev builds without the injection, and —
/// via the compile gate — every Local build) the heartbeat is fully inert.
///
/// Off the audio-critical path: every send is a detached URLSession task whose
/// result is ignored; a dead dashboard produces one log line and never blocks
/// or delays recording start/stop or the state machine.
final class SessionHeartbeat {
	static let shared = SessionHeartbeat()

	private init() {}

	/// Stable per app launch → one dashboard row per running Cloud instance.
	private let sessionId = UUID().uuidString
	/// Beat every 30 s. The Worker's stale window is 90 s, so this holds a live
	/// session across two missed beats before it could read as Stale.
	private static let intervalSeconds: TimeInterval = 30
	/// After a recording stops, keep beating "idle" for this long, then go fully
	/// silent. A left-open idle app must not beat forever: the Workers KV free
	/// tier is ~1,000 puts/day and unbounded 30 s idle beats blow it ~3× from one
	/// instance. 5 min covers the window in which a producer distinguishes a
	/// clean stop (Recording→Idle) from a crash (Recording→Stale); past it,
	/// "open but idle" and "closed" are indistinguishable anyway, so the Worker's
	/// TTL cleanup takes over (last beat → Stale +90 s → cleared +180 s).
	private static let idleWindowSeconds: TimeInterval = 300

	// Mutated only on the main thread (all entry points are main-thread VM calls).
	private var guestName = ""
	private var reportedState = "idle"
	private var timer: Timer?
	private var active = false
	/// When the current idle window ends — set on stop, cleared on record. Once
	/// a timer tick finds us idle past this, the timer stops itself. `timer ==
	/// nil` is the "silent" sentinel the re-arm path checks.
	private var idleDeadline: Date?

	// MARK: - Config (Info.plist, Cloud-injected; empty → inert)

	private static func nonEmptyInfoValue(for key: String) -> String? {
		guard let raw = Bundle.main.infoDictionary?[key] as? String else { return nil }
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}

	private static var ingestURL: URL? {
		guard let raw = nonEmptyInfoValue(for: "IngestURL") else { return nil }
		return URL(string: raw)
	}
	private static var clientId: String? { nonEmptyInfoValue(for: "IngestClientId") }
	private static var clientSecret: String? { nonEmptyInfoValue(for: "IngestClientSecret") }

	/// The build's own version ("2.5.6cr"), so the dashboard can show which
	/// release each guest is running. Omitted from the beat when absent; the
	/// Worker then falls back to the build number in the User-Agent, which is
	/// all a copy from before this field sends.
	private static let appVersion = nonEmptyInfoValue(for: "CFBundleShortVersionString")

	/// True only when the ingest URL and both service-token halves are present.
	private static var isConfigured: Bool {
		ingestURL != nil && clientId != nil && clientSecret != nil
	}

	/// Supplies `SessionDiagnostics` for each beat. Set by RecorderViewModel;
	/// called on the main thread, where every beat is sent from. Nil sends
	/// the beat without them.
	var diagnostics: (() -> [String: Any])?

	// MARK: - Public API (called from RecorderViewModel, main thread)

	/// A recording just started. Activates the heartbeat (first call only),
	/// records the guest name, and beats "recording" immediately so the session
	/// appears on the dashboard without waiting a full interval.
	func recordingStarted(guestName: String?) {
		guard Self.isConfigured else { return }
		self.guestName = (guestName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		reportedState = "recording"
		idleDeadline = nil
		active = true
		// Arm on first use, or RE-ARM if a prior idle window went silent.
		if timer == nil {
			startTimer()
		}
		sendBeat()
	}

	/// The app's recording state changed. Fired from a `$state` sink so every
	/// exit from `.recording` is caught (stop, upload, error, disconnect,
	/// first-buffer failure). No-op until the first `recordingStarted`, so the
	/// app doesn't beat while idle at launch before any guest is known.
	func recordingStateChanged(isRecording: Bool) {
		guard active else { return }
		let next = isRecording ? "recording" : "idle"
		guard next != reportedState else { return }
		reportedState = next
		if next == "recording" {
			idleDeadline = nil
			// Re-arm if a prior idle window silenced the timer. (In practice the
			// synchronous recordingStarted() above already re-armed; this covers
			// any path that reaches "recording" through the state sink alone.)
			if timer == nil { startTimer() }
		} else {
			// Start the bounded idle window; the timer self-stops at the deadline.
			idleDeadline = Date().addingTimeInterval(Self.idleWindowSeconds)
		}
		sendBeat() // reflect the transition immediately, don't wait for the timer
	}

	/// Stop beating and return to the pre-`recordingStarted` inert state. Used
	/// when the user turns cloud features off mid-session: the dashboard should
	/// see this instance go silent (row ages to Stale, then TTL-clears) rather
	/// than keep receiving "idle" from an app that is no longer participating.
	/// A later `recordingStarted` re-arms cleanly.
	func deactivate() {
		active = false
		reportedState = "idle"
		idleDeadline = nil
		stopTimer()
	}

	// MARK: - Internals

	private func startTimer() {
		timer?.invalidate()
		let t = Timer.scheduledTimer(withTimeInterval: Self.intervalSeconds, repeats: true) { [weak self] _ in
			self?.timerFired()
		}
		// Keep beating while modal run loops (name prompt, alerts) are active.
		RunLoop.main.add(t, forMode: .common)
		timer = t
	}

	/// Timer tick: send the current beat, unless the idle window has elapsed — in
	/// which case go fully silent (no final "offline" beat; the Worker's TTL
	/// clears the session). A later recording re-arms via recordingStarted.
	private func timerFired() {
		if reportedState == "idle", let deadline = idleDeadline, Date() >= deadline {
			stopTimer()
			return
		}
		sendBeat()
	}

	private func stopTimer() {
		timer?.invalidate()
		timer = nil
	}

	/// POST the current {sessionId, guestName, state, version} and the
	/// diagnostics to the ingest endpoint. Detached and result-ignored — never
	/// awaited, never fails the take.
	private func sendBeat() {
		guard let url = Self.ingestURL,
			  let clientId = Self.clientId,
			  let clientSecret = Self.clientSecret else { return }

		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue(clientId, forHTTPHeaderField: "CF-Access-Client-Id")
		request.setValue(clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
		var beat: [String: Any] = [
			"sessionId": sessionId,
			"guestName": guestName,
			"state": reportedState,
		]
		if let version = Self.appVersion {
			beat["version"] = version
		}
		// The diagnostics ride along but never replace the fields above, and
		// a value JSON can't carry (a NaN, say, which makes JSONSerialization
		// raise) costs them, never the beat.
		if let extra = diagnostics?() {
			let withDiagnostics = beat.merging(extra) { own, _ in own }
			if JSONSerialization.isValidJSONObject(withDiagnostics) {
				beat = withDiagnostics
			}
		}
		request.httpBody = try? JSONSerialization.data(withJSONObject: beat)

		// Diagnostics follow the FR-004 discipline: log only the HTTP status or
		// the error category — never the service-token secret, the URL, or the
		// guest name.
		URLSession.shared.dataTask(with: request) { _, response, error in
			if let error {
				logger.error("Heartbeat send failed: \(error.localizedDescription, privacy: .public)")
			} else if let http = response as? HTTPURLResponse,
					  !(200...299).contains(http.statusCode) {
				logger.error("Heartbeat returned HTTP \(http.statusCode, privacy: .public)")
			}
		}.resume()
	}
}
#endif

// MARK: - Diagnostics

/// What the Cloud heartbeat tells the dashboard about the guest's Mac, input
/// and take, so a producer can troubleshoot a session from afar: which macOS
/// and which Mac, what kind of input in what format, whether the take is
/// healthy, and how the last one ended.
///
/// Privacy: facts about the hardware and software, never about the person.
/// No computer or account name, serial number, hardware UUID, device UID,
/// file name or path, and no error text, which can carry a device's name:
/// failures go as categories (`CaptureFailure`, `TakeEnd`). An input's own
/// name goes only when its transport means the hardware supplies it —
/// built-in, USB, Thunderbolt, PCI, FireWire, HDMI, DisplayPort. A Bluetooth
/// headset, an iPhone, or an aggregate or virtual device is often named after
/// its owner ("Jane's AirPods"), so for those the dashboard gets the
/// transport and manufacturer alone.
enum SessionDiagnostics {

	// MARK: This Mac

	/// macOS, the Mac and this process. Fixed for the life of the app.
	struct SystemInfo: Equatable {
		/// "15.6.1 (24G90)": the version and build.
		let os: String
		/// The model identifier, "Mac14,2": the kind of Mac, not this one.
		let model: String?
		/// "Apple M2", or an Intel brand string.
		let chip: String?
		/// What this process runs as: "arm64" or "x86_64".
		let arch: String
		/// True when an x86_64 process runs under Rosetta.
		let translated: Bool
		/// Physical memory, whole GB.
		let memoryGB: Int

		static let current = SystemInfo(
			os: SessionDiagnostics.osDescription(),
			model: SessionDiagnostics.sysctlString("hw.model"),
			chip: SessionDiagnostics.sysctlString("machdep.cpu.brand_string"),
			arch: SessionDiagnostics.processArchitecture,
			translated: SessionDiagnostics.sysctlInt("sysctl.proc_translated") == 1,
			memoryGB: Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
		)

		var json: [String: Any] {
			var json: [String: Any] = [
				"os": os, "arch": arch, "translated": translated, "memoryGB": memoryGB,
			]
			if let model { json["model"] = model }
			if let chip { json["chip"] = chip }
			return json
		}
	}

	static var processArchitecture: String {
		#if arch(arm64)
		return "arm64"
		#elseif arch(x86_64)
		return "x86_64"
		#else
		return "other"
		#endif
	}

	/// "15.6.1 (24G90)", or the version alone if the build can't be read.
	static func osDescription() -> String {
		let version = ProcessInfo.processInfo.operatingSystemVersion
		var text = "\(version.majorVersion).\(version.minorVersion)"
		if version.patchVersion > 0 { text += ".\(version.patchVersion)" }
		guard let build = sysctlString("kern.osversion") else { return text }
		return "\(text) (\(build))"
	}

	static func sysctlString(_ name: String) -> String? {
		var size = 0
		guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
		var buffer = [CChar](repeating: 0, count: size)
		guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
		let value = buffer.withUnsafeBufferPointer { pointer -> String in
			guard let base = pointer.baseAddress else { return "" }
			return String(cString: base)
		}
		return clipped(value)
	}

	static func sysctlInt(_ name: String) -> Int? {
		var value: Int32 = 0
		var size = MemoryLayout<Int32>.size
		guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
		return Int(value)
	}

	// MARK: The input

	/// The bound input: what kind of device, and the format it delivers.
	struct InputInfo: Equatable {
		/// "usb", "builtIn", "bluetooth", …
		let transport: String
		let manufacturer: String?
		/// The device's name, only where the hardware supplies it.
		let name: String?
		let sampleRate: Int?
		let channels: Int?
		/// "int24", "float32 planar", …
		let sampleFormat: String?
		/// "none", "Stereo", "L R", "DiscreteInOrder 2", …
		let layout: String?
		/// True when `PCMSidecar.writerMixGains` knows this layout, so the
		/// meter shows the level the file records; false when it falls back
		/// and the two can differ.
		let meterMatchesFile: Bool?

		/// `format` is the last capture buffer's, nil before the first one.
		init(transport: UInt32?, manufacturer: String?, name: String?, format: CMFormatDescription?) {
			self.transport = SessionDiagnostics.transportName(transport)
			self.manufacturer = SessionDiagnostics.clipped(manufacturer)
			self.name = SessionDiagnostics.reportableName(name, transport: transport)
			guard let format,
				  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
				sampleRate = nil
				channels = nil
				sampleFormat = nil
				layout = nil
				meterMatchesFile = nil
				return
			}
			sampleRate = asbd.mSampleRate.isFinite ? Int(asbd.mSampleRate.rounded()) : nil
			channels = Int(asbd.mChannelsPerFrame)
			sampleFormat = SessionDiagnostics.sampleFormat(asbd)
			layout = SessionDiagnostics.layoutDescription(format)
			meterMatchesFile = PCMSidecar.writerMixGains(
				for: format, channels: max(Int(asbd.mChannelsPerFrame), 1)
			) != nil
		}

		var json: [String: Any] {
			var json: [String: Any] = ["transport": transport]
			if let manufacturer { json["manufacturer"] = manufacturer }
			if let name { json["name"] = name }
			if let sampleRate { json["sampleRate"] = sampleRate }
			if let channels { json["channels"] = channels }
			if let sampleFormat { json["sampleFormat"] = sampleFormat }
			if let layout { json["layout"] = layout }
			if let meterMatchesFile { json["meterMatchesFile"] = meterMatchesFile }
			return json
		}
	}

	/// Transports whose devices take their names from the hardware or its
	/// driver. On the others — Bluetooth, AirPlay, Continuity, AVB,
	/// aggregate and virtual devices — the name can be one the owner chose.
	private static let hardwareNamedTransports: Set<UInt32> = [
		kAudioDeviceTransportTypeBuiltIn,
		kAudioDeviceTransportTypeUSB,
		kAudioDeviceTransportTypeThunderbolt,
		kAudioDeviceTransportTypePCI,
		kAudioDeviceTransportTypeFireWire,
		kAudioDeviceTransportTypeHDMI,
		kAudioDeviceTransportTypeDisplayPort,
	]

	/// `name`, if a device on this transport takes its name from the hardware.
	static func reportableName(_ name: String?, transport: UInt32?) -> String? {
		guard let transport, hardwareNamedTransports.contains(transport) else { return nil }
		return clipped(name)
	}

	static func transportName(_ transport: UInt32?) -> String {
		guard let transport else { return "unknown" }
		switch transport {
		case kAudioDeviceTransportTypeBuiltIn: return "builtIn"
		case kAudioDeviceTransportTypeUSB: return "usb"
		case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
		case kAudioDeviceTransportTypeBluetoothLE: return "bluetoothLE"
		case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
		case kAudioDeviceTransportTypePCI: return "pci"
		case kAudioDeviceTransportTypeFireWire: return "firewire"
		case kAudioDeviceTransportTypeHDMI: return "hdmi"
		case kAudioDeviceTransportTypeDisplayPort: return "displayPort"
		case kAudioDeviceTransportTypeAirPlay: return "airPlay"
		case kAudioDeviceTransportTypeAVB: return "avb"
		case kAudioDeviceTransportTypeAggregate: return "aggregate"
		case kAudioDeviceTransportTypeVirtual: return "virtual"
		case kAudioDeviceTransportTypeUnknown: return "unknown"
		default:
			let code = fourCC(transport)
			// Continuity Camera's iPhone microphone: 'ccap', wired 'ccwd',
			// wireless 'ccwl'.
			return ["ccap", "ccwd", "ccwl"].contains(code) ? "continuity" : "other:\(code)"
		}
	}

	/// "int24", "float32 planar", or the format's four-character code if it
	/// isn't linear PCM.
	static func sampleFormat(_ asbd: AudioStreamBasicDescription) -> String {
		guard asbd.mFormatID == kAudioFormatLinearPCM else { return fourCC(asbd.mFormatID) }
		let kind: String
		if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
			kind = "float"
		} else if asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
			kind = "int"
		} else {
			kind = "uint"
		}
		let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 && asbd.mChannelsPerFrame > 1
		return "\(kind)\(asbd.mBitsPerChannel)" + (planar ? " planar" : "")
	}

	/// The format's channel layout: "none", a tag's name ("Stereo",
	/// "DiscreteInOrder 2"), or the listed labels ("L R", "D0 D1").
	static func layoutDescription(_ format: CMFormatDescription) -> String {
		var size = 0
		guard let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size) else {
			return "none"
		}
		let tag = layout.pointee.mChannelLayoutTag
		switch tag {
		case kAudioChannelLayoutTag_UseChannelDescriptions, kAudioChannelLayoutTag_UseChannelBitmap:
			guard let labels = PCMSidecar.channelLabels(in: layout, size: size) else { return "malformed" }
			return labels.isEmpty ? "empty" : labels.map(labelName).joined(separator: " ")
		default:
			if tag & 0xFFFF_0000 == kAudioChannelLayoutTag_DiscreteInOrder {
				return "DiscreteInOrder \(tag & 0xFFFF)"
			}
			if let name = tagNames[tag] { return name }
			// A tag is a layout number and a channel count.
			return "tag \(tag >> 16)/\(tag & 0xFFFF)"
		}
	}

	private static let tagNames: [AudioChannelLayoutTag: String] = [
		kAudioChannelLayoutTag_Mono: "Mono",
		kAudioChannelLayoutTag_Stereo: "Stereo",
		kAudioChannelLayoutTag_StereoHeadphones: "StereoHeadphones",
		kAudioChannelLayoutTag_MatrixStereo: "MatrixStereo",
		kAudioChannelLayoutTag_MidSide: "MidSide",
		kAudioChannelLayoutTag_XY: "XY",
		kAudioChannelLayoutTag_Binaural: "Binaural",
		kAudioChannelLayoutTag_Quadraphonic: "Quadraphonic",
	]

	private static func labelName(_ label: AudioChannelLabel) -> String {
		if label & 0xFFFF_0000 == kAudioChannelLabel_Discrete_0 {
			return "D\(label & 0xFFFF)"
		}
		switch label {
		case kAudioChannelLabel_Left: return "L"
		case kAudioChannelLabel_Right: return "R"
		case kAudioChannelLabel_Center: return "C"
		case kAudioChannelLabel_LFEScreen: return "LFE"
		case kAudioChannelLabel_LeftSurround: return "Ls"
		case kAudioChannelLabel_RightSurround: return "Rs"
		case kAudioChannelLabel_Mono: return "M"
		case kAudioChannelLabel_HeadphonesLeft: return "HL"
		case kAudioChannelLabel_HeadphonesRight: return "HR"
		case kAudioChannelLabel_MS_Mid: return "Mid"
		case kAudioChannelLabel_MS_Side: return "Side"
		case kAudioChannelLabel_Unknown: return "?"
		case kAudioChannelLabel_Unused: return "-"
		default: return "#\(label)"
		}
	}

	// MARK: The last take

	/// How a take ended.
	enum TakeEnd: String {
		/// The file was finalized.
		case saved
		/// The file couldn't be finalized; the sidecar was re-wrapped at stop.
		case recovered
		/// The sidecar holds the audio, left for the next launch to recover.
		case recoverAtLaunch
		/// Nothing was written.
		case noAudio
		/// The file couldn't be finalized, and there is nothing to recover.
		case failed
	}

	/// How the last take went.
	struct TakeInfo: Equatable {
		var end: TakeEnd
		/// "user", "diskSpace", or a `CaptureFailure`.
		let cause: String
		let seconds: Int
		let droppedFrames: Bool
		let interruptions: Int
		/// `crashBackupState`.
		let crashBackup: String

		var json: [String: Any] {
			[
				"end": end.rawValue, "cause": cause, "seconds": seconds,
				"droppedFrames": droppedFrames, "interruptions": interruptions,
				"crashBackup": crashBackup,
			]
		}
	}

	/// How a stop ended, from the engine's result. A failed take whose
	/// sidecar holds audio counts as recovered: the stop re-wraps it at once,
	/// and the caller changes that to `.recoverAtLaunch` if it can't.
	static func takeEnd(result: Result<URL?, Error>, sidecarHasAudio: Bool) -> TakeEnd {
		switch result {
		case .success(.some):
			return .saved
		case .success(.none):
			return .noAudio
		case .failure(let error):
			if sidecarHasAudio { return .recovered }
			if let recordingError = error as? RecordingError,
			   case .noActiveRecording = recordingError {
				return .noAudio
			}
			return .failed
		}
	}

	/// Why a take ended: the disk watch, the engine (a `CaptureFailure`), or
	/// the user.
	static func takeCause(diskStop: Bool, engineStop: Bool, failure: CaptureFailure?) -> String {
		if diskStop { return "diskSpace" }
		if engineStop { return failure?.rawValue ?? "engine" }
		return "user"
	}

	/// The crash backup: "ok", "unavailable" (the sidecar never opened) or
	/// "failed" (a write to it failed mid-take).
	static func crashBackupState(unavailable: Bool, failed: Bool) -> String {
		if unavailable { return "unavailable" }
		return failed ? "failed" : "ok"
	}

	// MARK: Helpers

	/// Trimmed, at most 64 characters, nil if empty.
	static func clipped(_ text: String?) -> String? {
		guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
			  !trimmed.isEmpty else { return nil }
		return String(trimmed.prefix(64))
	}

	/// A four-character code as text, "lpcm"; hex if it isn't printable.
	static func fourCC(_ code: UInt32) -> String {
		let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
		guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else {
			return String(format: "0x%08X", code)
		}
		return String(decoding: bytes, as: UTF8.self)
	}
}
