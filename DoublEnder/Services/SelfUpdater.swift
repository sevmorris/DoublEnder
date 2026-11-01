import AppKit
import Security

/// Installs a new version over the running app, so an update takes one click
/// rather than a DMG to open and a drag to Applications.
///
/// What makes a download trustworthy is its signature, not where it came from.
/// Every release's DMG and the app inside it are signed with the Developer ID
/// below, and nothing is mounted or installed until the signature checks out.
/// No key or feed exists beyond what a release already publishes.
///
/// The swap happens in this process, while the app is still running. macOS
/// lets an app change one signed by its own team without the App Management
/// permission, and it holds whoever makes the change responsible, which a
/// helper left running after the app quits would blur.
enum SelfUpdater {

    /// Why this copy cannot replace itself. Each falls back to the Download
    /// button, which needs none of this.
    enum Obstacle: Equatable {
        /// A development build: it would be replacing itself, wherever Xcode
        /// put it, with something that is not what it was built from.
        case notARelease
        /// On a mounted DMG, or translocated by Gatekeeper because it was
        /// opened where it was downloaded without being moved.
        case readOnlyLocation
        /// Installed by another user on this Mac, for one.
        case notWritable
    }

    enum Failure: LocalizedError, Equatable {
        case http(Int)
        case untrusted
        case notNewer
        case needsNewerMacOS(String)
        case wrongArchitecture
        case diskImage
        case copy
        case swap(String)

        var errorDescription: String? {
            switch self {
            case .http(let status):
                return "The download failed (HTTP \(status))."
            case .untrusted:
                return "The download isn't a signed release of this app, so nothing was installed."
            case .notNewer:
                // A release is public moments before its DMG reaches the
                // download link, and the link is cached for a minute.
                return "The new version is still being published. Try again in a few minutes."
            case .needsNewerMacOS(let minimum):
                return "The new version needs macOS \(minimum)."
            case .wrongArchitecture:
                return "The new version doesn't run on this Mac's processor."
            case .diskImage:
                return "The downloaded disk image couldn't be opened."
            case .copy:
                return "The new version couldn't be copied out of its disk image."
            case .swap(let reason):
                return "The app couldn't be replaced: \(reason)."
            }
        }
    }

    // MARK: - Trust

    /// Every release's designated requirement, less its identifier: a Developer
    /// ID Application certificate from Apple, issued to this team. A DMG meets
    /// this one alone, because its identifier is taken from its file name.
    static let developerIDRequirement = """
        anchor apple generic \
        and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
        and certificate leaf[subject.OU] = "T9RLNAXPWU"
        """

    static func appRequirement(bundleID: String) -> String {
        "identifier \"\(bundleID)\" and \(developerIDRequirement)"
    }

    /// True when the app or disk image at `url` is intact, in every
    /// architecture and nested item, and signed as `requirement` says.
    static func isSigned(_ url: URL, requirement: String) -> Bool {
        var code: SecStaticCode?
        var parsed: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, parsed) == errSecSuccess
    }

    // MARK: - Whether this copy can update

    static func obstacle(for app: URL, requirement: String) -> Obstacle? {
        guard isSigned(app, requirement: requirement) else { return .notARelease }
        let readOnly = (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        if readOnly || isTranslocated(app) { return .readOnlyLocation }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: app.path),
              fm.isWritableFile(atPath: app.deletingLastPathComponent().path) else { return .notWritable }
        return nil
    }

    static func isTranslocated(_ app: URL) -> Bool {
        app.path.contains("/AppTranslocation/")
    }

    // MARK: - Vetting a new version

    /// What a download has to be to replace this copy.
    struct Expected {
        var bundleID: String
        var installedVersion: String
        var appRequirement: String
        var diskImageRequirement = SelfUpdater.developerIDRequirement
        var os = ProcessInfo.processInfo.operatingSystemVersion
        var architecture = SelfUpdater.runningArchitecture

        static func running(_ bundle: Bundle) -> Expected {
            let bundleID = bundle.bundleIdentifier ?? ""
            return Expected(bundleID: bundleID,
                            installedVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                            appRequirement: SelfUpdater.appRequirement(bundleID: bundleID))
        }
    }

    static var runningArchitecture: Int {
        #if arch(arm64)
        NSBundleExecutableArchitectureARM64
        #else
        NSBundleExecutableArchitectureX86_64
        #endif
    }

    /// Everything that would leave a Mac with a worse app than it has: the
    /// update replaces the only copy, so an app that will not open here has to
    /// be stopped now. The arm64-only builds that once shipped as universal
    /// would have broken every Intel Mac this way.
    static func vet(_ app: URL, against expected: Expected) throws {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == expected.bundleID,
              isSigned(app, requirement: expected.appRequirement) else { throw Failure.untrusted }

        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard VersionFormatting.numericVersion(version)
            .compare(VersionFormatting.numericVersion(expected.installedVersion), options: .numeric) == .orderedDescending
        else { throw Failure.notNewer }

        if let minimum = (bundle.infoDictionary?["LSMinimumSystemVersion"] as? String).flatMap(UpdateChecker.macOSVersion),
           !UpdateChecker.runs(on: expected.os, given: minimum) {
            throw Failure.needsNewerMacOS(UpdateChecker.describe(minimum))
        }
        guard bundle.executableArchitectures?.contains(where: { $0.intValue == expected.architecture }) == true
        else { throw Failure.wrongArchitecture }
    }

    /// The one app at the top of a mounted release DMG, whatever it is named.
    /// Beside it are only the /Applications link and the installer window's art.
    static func app(in volume: URL) throws -> URL {
        let entries = (try? FileManager.default.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil)) ?? []
        let apps = entries.filter { $0.pathExtension == "app" }
        guard apps.count == 1 else { throw Failure.untrusted }
        return apps[0]
    }

    // MARK: - Staging

    /// Downloads a release and leaves a vetted copy of its app on the same
    /// volume as `installed`, where the swap can be a rename. The caller
    /// disposes of it with `discard`.
    static func stage(from url: URL, replacing installed: URL, expected: Expected,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoublEnderUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let dmg = scratch.appendingPathComponent("update.dmg")
        try await UpdateDownload.fetch(url, to: dmg, progress: progress)
        try Task.checkCancellation()
        let staged = try await Task.detached {
            try stage(diskImage: dmg, replacing: installed, expected: expected)
        }.value
        do {
            try Task.checkCancellation()
        } catch {
            discard(staged)
            throw error
        }
        return staged
    }

    /// The disk image half of `stage`. It blocks while the image mounts and copies.
    static func stage(diskImage dmg: URL, replacing installed: URL, expected: Expected) throws -> URL {
        // Before hdiutil has to parse it: an unsigned image is never mounted.
        guard isSigned(dmg, requirement: expected.diskImageRequirement) else { throw Failure.untrusted }

        let mountPoint = dmg.deletingLastPathComponent().appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-mountpoint", mountPoint.path,
                                       "-nobrowse", "-noautoopen", "-readonly", "-quiet"]) else {
            throw Failure.diskImage
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"]) }

        let app = try app(in: mountPoint)
        try vet(app, against: expected)

        let holder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                 appropriateFor: installed, create: true)
        let staged = holder.appendingPathComponent(installed.lastPathComponent)
        do {
            guard run("/usr/bin/ditto", [app.path, staged.path]) else { throw Failure.copy }
            // The copy is what gets installed, so it is the one that has to pass.
            guard isSigned(staged, requirement: expected.appRequirement) else { throw Failure.copy }
        } catch {
            discard(staged)
            throw error
        }
        return staged
    }

    /// Removes a staged copy and the folder made for it. After a swap, that
    /// copy is the previous version.
    static func discard(_ staged: URL) {
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Installing

    /// Exchanges the staged app and the installed one in a single step, so a
    /// failure at any point leaves the installed app whole. The running process
    /// keeps its own files open and carries on until it quits.
    static func swap(staged: URL, into installed: URL) throws {
        guard renamex_np(staged.path, installed.path, UInt32(RENAME_SWAP)) == 0 else {
            throw Failure.swap(String(cString: strerror(errno)))
        }
    }

    /// Opens `app` once this process has gone, so two recorders never hold the
    /// input at once. It gives up after a minute rather than linger if the quit
    /// is somehow refused.
    static func relaunch(_ app: URL) throws {
        let script = """
            i=0
            while kill -0 "$1" 2>/dev/null; do
                i=$((i + 1))
                [ "$i" -gt 300 ] && exit 1
                sleep 0.2
            done
            exec /usr/bin/open "$2"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), app.path]
        try process.run()
    }
}

// MARK: - Download

/// A download with progress. The async `download(for:delegate:)` does not report
/// any, so this keeps to the delegate calls, which run on the session's serial queue.
private final class UpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    private init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = UpdateDownload(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        let task = session.downloadTask(with: request)
        session.finishTasksAndInvalidate()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    /// The file is deleted when this returns, so it has to move now.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            failure = SelfUpdater.Failure.http(status)
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let problem = error ?? failure {
            continuation?.resume(throwing: problem)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}

// MARK: - Progress window

/// Shows how the update is going, with a way out.
///
/// This window is not modal, on purpose. The update runs on the main actor, and
/// `checkForUpdates` is a main actor task: a modal run loop started inside one
/// stops the main queue being serviced, so the download could never report back
/// or finish. It is why the recorder stays usable, too, and why installing
/// waits for a take rather than refusing to start.
@MainActor
final class UpdateProgressWindow: NSObject {
    private let window: NSWindow
    private let label = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private var onCancel: (() -> Void)?

    init(title: String) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                          styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true

        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.style = .bar

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [NSView(), cancel])
        let stack = NSStackView(views: [label, bar, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: 380),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
    }

    func setCancelAction(_ action: @escaping () -> Void) {
        onCancel = action
    }

    func show() {
        window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
        // `center()` always picks the primary screen; the recorder may be elsewhere.
        let screen = NSApp.windows.first { $0 is FaceplateWindow }?.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
        }
        bringForward()
    }

    func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
    }

    func showProgress(_ message: String, fraction: Double?) {
        label.stringValue = message
        if let fraction {
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
            bar.doubleValue = fraction
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
    }

    @objc private func cancelPressed() {
        onCancel?()
    }
}
