import Foundation
import OSLog

// Branded-only: compiled into Cloud builds (branded builds *are* Cloud builds)
// and stripped entirely from the public Local build, exactly like the other
// #if GCS_ENABLED surfaces in the shared tree.
#if GCS_ENABLED
private let logger = Logger(subsystem: "io.github.sevmorris.DoublEnder", category: "NtfyService")

/// Fire-and-forget ntfy notifications to the engineer who monitors recording
/// sessions. Singleton to mirror `NotificationService` — there's no per-call
/// state and nothing to register, but a single instance keeps the call sites
/// symmetrical with the rest of the app's services.
///
/// The ntfy topic URL comes from the bundle's `NtfyTopicURL` Info.plist key,
/// injected per-brand at build time (brand.conf → release-branded.sh xcodebuild
/// override → Info.plist `$(VAR)` substitution). This is the same pattern as
/// `DefaultRecordingPrefix` / `RequireRecordingNameAtStart` /
/// `DeleteLocalAfterUpload`. When the key is absent or empty — standard Cloud
/// and (via the compile gate) public Local — `topicURL` is nil and every call
/// is a silent no-op. That runtime guard is what makes the feature branded-only
/// even within a Cloud build. Works with ntfy.sh or a self-hosted server.
final class NtfyService {
    static let shared = NtfyService()

    private init() {}

    /// ntfy topic URL from the bundle's `NtfyTopicURL` key, or nil when the key
    /// is absent/empty or doesn't parse as a URL. Read fresh each call (matching
    /// the Info.plist-reading static vars in `RecorderViewModel`); the value
    /// never changes for the life of the process.
    static var topicURL: URL? {
        guard let raw = nonEmptyInfoValue(for: "NtfyTopicURL") else { return nil }
        return URL(string: raw)
    }

    /// Trimmed, non-empty Info.plist string for `key`, or nil. An empty string
    /// is the unset-build-setting substitution result, so it's treated as
    /// absent.
    private static func nonEmptyInfoValue(for key: String) -> String? {
        guard let raw = Bundle.main.infoDictionary?[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Notify the monitoring engineer that a guest started recording. `name` is
    /// the sanitized-or-raw recording name (the value passed as
    /// `startRecording(nameOverride:)`); when present and non-empty the body
    /// reads "<name> started recording", otherwise "Recording started".
    ///
    /// No-op unless a topic URL is configured for this build. Fire-and-forget —
    /// it never blocks or fails the take.
    func notifyRecordingStarted(name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if let trimmed, !trimmed.isEmpty {
            body = "\(trimmed) started recording"
        } else {
            body = "Recording started"
        }
        // Title carries the brand so an engineer monitoring several clients can
        // tell at a glance which one a notification came from (e.g. "DoublEnder · …").
        send(body: body, title: Self.displayName)
    }

    /// Notify the monitoring engineer that a guest stopped recording — the
    /// complement of `notifyRecordingStarted(name:)`. `name` is the same
    /// `nameOverride` value passed at start; when present and non-empty the body
    /// reads "<name> stopped recording", otherwise "Recording stopped".
    ///
    /// No-op unless a topic URL is configured for this build. Fire-and-forget —
    /// it never blocks or fails finalization.
    func notifyRecordingStopped(name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if let trimmed, !trimmed.isEmpty {
            body = "\(trimmed) stopped recording"
        } else {
            body = "Recording stopped"
        }
        send(body: body, title: Self.displayName)
    }

    /// App display name (CFBundleDisplayName) for use as the notification title,
    /// or "DoublEnder" as a fallback.
    private static var displayName: String {
        nonEmptyInfoValue(for: "CFBundleDisplayName") ?? "DoublEnder"
    }

    /// POST a single message to the configured ntfy topic. Guards on the topic
    /// URL being present, then fires a detached `URLSession` task whose result
    /// we never await — a missed notification must not disrupt recording. The
    /// title rides in ntfy's `Title` header; the body is the plain-text payload.
    private func send(body: String, title: String) {
        guard let url = Self.topicURL else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.setValue(title, forHTTPHeaderField: "Title")
        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                logger.error("ntfy notify failed: \(error.localizedDescription, privacy: .public)")
            } else if let http = response as? HTTPURLResponse,
                      !(200...299).contains(http.statusCode) {
                logger.error("ntfy notify returned HTTP \(http.statusCode, privacy: .public)")
            }
        }.resume()
    }
}
#endif
