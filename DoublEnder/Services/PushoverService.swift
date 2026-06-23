import Foundation
import OSLog

// Branded-only: compiled into Cloud builds (branded builds *are* Cloud builds)
// and stripped entirely from the public Local build, exactly like the other
// #if GCS_ENABLED surfaces in the shared tree.
#if GCS_ENABLED
private let logger = Logger(subsystem: "io.github.sevmorris.DoublEnder", category: "PushoverService")

/// Fire-and-forget Pushover push notifications to the engineer who monitors
/// recording sessions. Singleton to mirror `NotificationService` — there's no
/// per-call state and nothing to register, but a single instance keeps the
/// call sites symmetrical with the rest of the app's services.
///
/// The Pushover app token and user key come from the bundle's
/// `PushoverAppToken` / `PushoverUserKey` Info.plist keys, injected per-brand
/// at build time (brand.conf → release-branded.sh xcodebuild override →
/// Info.plist `$(VAR)` substitution). This is the same pattern as
/// `DefaultRecordingPrefix` / `RequireRecordingNameAtStart` /
/// `DeleteLocalAfterUpload`. When the keys are absent or empty — standard
/// Cloud and (via the compile gate) public Local — `isConfigured` is false and
/// every call is a silent no-op. That runtime guard is what makes the feature
/// branded-only even within a Cloud build.
final class PushoverService {
    static let shared = PushoverService()

    private static let messagesURL = URL(string: "https://api.pushover.net/1/messages.json")!

    private init() {}

    /// Pushover app token from the bundle's `PushoverAppToken` key, or nil when
    /// absent/empty. Read fresh each call (matching the Info.plist-reading
    /// static vars in `RecorderViewModel`); the value never changes for the
    /// life of the process.
    static var appToken: String? {
        nonEmptyInfoValue(for: "PushoverAppToken")
    }

    /// Pushover user/group key from the bundle's `PushoverUserKey` key, or nil
    /// when absent/empty.
    static var userKey: String? {
        nonEmptyInfoValue(for: "PushoverUserKey")
    }

    /// True only when *both* credentials are present. The runtime gate that
    /// keeps standard Cloud builds inert — they ship neither key.
    static var isConfigured: Bool {
        appToken != nil && userKey != nil
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
    /// `startRecording(nameOverride:)`); when present and non-empty the message
    /// reads "<name> started recording", otherwise "Recording started".
    ///
    /// No-op unless Pushover is configured for this build. Fire-and-forget — it
    /// never blocks or fails the take.
    func notifyRecordingStarted(name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message: String
        if let trimmed, !trimmed.isEmpty {
            message = "\(trimmed) started recording"
        } else {
            message = "Recording started"
        }
        // Title carries the brand so an engineer monitoring several clients can
        // tell at a glance which one a push came from (e.g. "DoublEnder · …").
        send(message: message, title: Self.displayName)
    }

    /// App display name (CFBundleDisplayName) for use as the push title, or
    /// "DoublEnder" as a fallback.
    private static var displayName: String {
        nonEmptyInfoValue(for: "CFBundleDisplayName") ?? "DoublEnder"
    }

    /// POST a single message to the Pushover messages API. Guards on the
    /// credentials being present, then fires a detached `URLSession` task whose
    /// result we never await — a missed push must not disrupt recording. The
    /// `title` and `priority` form fields are optional per the Pushover API.
    private func send(message: String, title: String? = nil, priority: Int? = nil) {
        guard let token = Self.appToken, let user = Self.userKey else { return }

        var fields = [
            "token": token,
            "user": user,
            "message": message,
        ]
        if let title { fields["title"] = title }
        if let priority { fields["priority"] = String(priority) }

        var request = URLRequest(url: Self.messagesURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(fields).data(using: .utf8)

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                logger.error("Pushover notify failed: \(error.localizedDescription, privacy: .public)")
            } else if let http = response as? HTTPURLResponse,
                      !(200...299).contains(http.statusCode) {
                logger.error("Pushover notify returned HTTP \(http.statusCode, privacy: .public)")
            }
        }.resume()
    }

    /// Percent-encode `fields` as `application/x-www-form-urlencoded`. Uses the
    /// RFC 3986 unreserved set so spaces in the message become `%20`.
    private static func formEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        .joined(separator: "&")
    }
}
#endif
