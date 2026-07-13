import Foundation
import OSLog

// Cloud-only: compiled into Cloud builds and stripped entirely from the public
// Local build, like the other #if GCS_ENABLED surfaces in the shared tree.
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

	// Mutated only on the main thread (all entry points are main-thread VM calls).
	private var guestName = ""
	private var reportedState = "idle"
	private var timer: Timer?
	private var active = false

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

	/// True only when the ingest URL and both service-token halves are present.
	private static var isConfigured: Bool {
		ingestURL != nil && clientId != nil && clientSecret != nil
	}

	// MARK: - Public API (called from RecorderViewModel, main thread)

	/// A recording just started. Activates the heartbeat (first call only),
	/// records the guest name, and beats "recording" immediately so the session
	/// appears on the dashboard without waiting a full interval.
	func recordingStarted(guestName: String?) {
		guard Self.isConfigured else { return }
		self.guestName = (guestName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		reportedState = "recording"
		if !active {
			active = true
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
		sendBeat() // reflect the transition immediately, don't wait for the timer
	}

	// MARK: - Internals

	private func startTimer() {
		timer?.invalidate()
		let t = Timer.scheduledTimer(withTimeInterval: Self.intervalSeconds, repeats: true) { [weak self] _ in
			self?.sendBeat()
		}
		// Keep beating while modal run loops (name prompt, alerts) are active.
		RunLoop.main.add(t, forMode: .common)
		timer = t
	}

	/// POST the current {sessionId, guestName, state} to the ingest endpoint.
	/// Detached and result-ignored — never awaited, never fails the take.
	private func sendBeat() {
		guard let url = Self.ingestURL,
			  let clientId = Self.clientId,
			  let clientSecret = Self.clientSecret else { return }

		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue(clientId, forHTTPHeaderField: "CF-Access-Client-Id")
		request.setValue(clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
		request.httpBody = try? JSONSerialization.data(withJSONObject: [
			"sessionId": sessionId,
			"guestName": guestName,
			"state": reportedState,
		])

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
