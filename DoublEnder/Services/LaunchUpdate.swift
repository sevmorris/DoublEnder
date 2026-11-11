#if GCS_ENABLED
import AppKit
import OSLog

private let logger = Logger(subsystem: "io.github.sevmorris.DoublEnder", category: "LaunchUpdate")

/// Cloud: brings a guest's copy up to date before the recorder opens.
///
/// A guest usually opens DoublEnder Cloud minutes before a session, and an
/// update prompt then is one more decision for someone who only wants to
/// record. So at launch, before the recorder is built, this checks the Cloud
/// manifest and, when a newer version is there and this copy can replace
/// itself, installs it and relaunches without asking.
///
/// Nothing here may keep a guest from recording. The check gets
/// `checkTimeout`; Skip is always there; and anything else (offline, up to
/// date, a Mac too old for the new version, a copy that can't replace itself,
/// a failed download) opens the recorder as usual. Where the usual prompt
/// after launch has something to add (a copy that has to be moved to
/// Applications first, a check that ran out of time), it still runs.
///
/// It uses SelfUpdater's own steps (stage, swap, relaunch), so a release is
/// vetted exactly as the prompt vets it. SelfUpdater.swift is shared verbatim
/// across the sibling apps, which is why this lives beside it rather than in it.
@MainActor
final class LaunchUpdate {
    /// How long the manifest check may hold up the recorder.
    static let checkTimeout: Duration = .seconds(5)

    private static let appName = "DoublEnder Cloud"

    private let window = LaunchUpdateWindow(title: appName)
    private let launch: (_ checkAfterLaunch: Bool) -> Void
    private var work: Task<Void, Never>?
    private var finished = false

    /// Starts the check, with its window on screen before this returns, so
    /// SwiftUI finds a window at launch and presents no scene of its own.
    /// `launch` opens the recorder; `checkAfterLaunch` says whether the usual
    /// update check after launch still has something to offer.
    /// It is not called when the update installs, since the app relaunches.
    @discardableResult
    static func run(then launch: @escaping (_ checkAfterLaunch: Bool) -> Void) -> LaunchUpdate {
        let update = LaunchUpdate(launch: launch)
        update.start()
        return update
    }

    private init(launch: @escaping (_ checkAfterLaunch: Bool) -> Void) {
        self.launch = launch
    }

    private func start() {
        window.showProgress("Checking for updates…", fraction: nil)
        window.onSkip = { [weak self] in
            guard let self else { return }
            self.work?.cancel()
            // The guest chose to go on, so the prompt after launch would only ask again.
            self.finish(checkAfterLaunch: false)
        }
        window.show()
        // The task holds self until it ends, and it ends in finish or a relaunch.
        work = Task { await self.update() }
    }

    private func update() async {
        let result = await Self.check(within: Self.checkTimeout)
        guard !finished else { return }

        let version: String
        let downloadURL: URL
        switch result {
        case .available(let available, let url, _):
            version = available
            downloadURL = url
        case .upToDate, .needsNewerMacOS:
            // The check after launch would find the same, and it says nothing either way.
            return finish(checkAfterLaunch: false)
        case .error(let message):
            logger.notice("Launch update check failed: \(message, privacy: .public)")
            return finish(checkAfterLaunch: true)
        case nil:
            logger.notice("Launch update check took longer than \(Self.checkTimeout, privacy: .public)")
            return finish(checkAfterLaunch: true)
        }

        let installed = Bundle.main.bundleURL
        let requirement = SelfUpdater.Expected.running(.main).appRequirement
        let obstacle = await Task.detached { SelfUpdater.obstacle(for: installed, requirement: requirement) }.value
        guard !finished else { return }
        if obstacle != nil {
            // The prompt after launch says what's in the way, and offers the download.
            return finish(checkAfterLaunch: true)
        }

        let downloading = "Downloading \(Self.appName) \(version)…"
        window.showProgress(downloading, fraction: 0)
        do {
            let request = URLRequest(url: downloadURL, cachePolicy: .reloadIgnoringLocalCacheData)
            let staged = try await SelfUpdater.stage(from: request, replacing: installed,
                                                     expected: .running(.main)) { [window] fraction in
                Task { @MainActor in
                    window.showProgress(fraction < 1 ? downloading : "Checking the download…",
                                        fraction: fraction < 1 ? fraction : nil)
                }
            }
            // Skipped while the image was being checked: the recorder is already open.
            guard !finished else { return SelfUpdater.discard(staged) }
            // No suspension from here to the quit, so Skip cannot land in between.
            do {
                try SelfUpdater.swap(staged: staged, into: installed)
            } catch {
                SelfUpdater.discard(staged)
                throw error
            }
            SelfUpdater.discard(staged)
            window.showProgress("Relaunching…", fraction: nil)
            do {
                try SelfUpdater.relaunch(installed)
            } catch {
                // The new version is in place and opens next time; this one carries on.
                logger.error("Relaunch after update failed: \(error.localizedDescription, privacy: .public)")
                return finish(checkAfterLaunch: false)
            }
            NSApp.terminate(nil)
        } catch {
            guard !finished else { return }
            logger.error("Launch update failed: \(error.localizedDescription, privacy: .public)")
            // The installed app is as it was. The prompt after launch offers the
            // update again, and the download when installing fails a second time.
            finish(checkAfterLaunch: true)
        }
    }

    /// Opens the recorder, once. This window leaves the screen first: building the
    /// recorder can block the main thread on the microphone prompt (a first launch),
    /// and "Checking for updates…" shouldn't sit behind it. The change reaches the
    /// screen only when the run loop next goes idle, so the recorder waits for that;
    /// the pause makes sure the run loop does.
    ///
    /// It turns transparent rather than ordering out: with no window on screen,
    /// AppKit counts the last window as closed even without a close, and this app
    /// then quits. It is closed once the recorder is up.
    private func finish(checkAfterLaunch: Bool) {
        guard !finished else { return }
        finished = true
        window.makeTransparent()
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            launch(checkAfterLaunch)
            window.close()
        }
    }

    /// The Cloud manifest check, or nil when it takes longer than `limit`.
    private static func check(within limit: Duration) async -> UpdateChecker.Result? {
        await withTaskGroup(of: UpdateChecker.Result?.self) { group in
            group.addTask { await UpdateChecker().check() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Window

/// What the guest sees while the check and the download run: a line, a bar and
/// Skip. It has no close button, since closing the app's only window would quit
/// it; Skip is the way out.
@MainActor
private final class LaunchUpdateWindow: NSObject {
    private let window: NSWindow
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    var onSkip: (() -> Void)?

    init(title: String) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 118),
                          styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false

        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1

        let skip = NSButton(title: "Skip", target: self, action: #selector(skipPressed))
        skip.bezelStyle = .push
        skip.keyEquivalent = "\u{1b}"

        guard let content = window.contentView else { return }
        for view in [label, bar, skip] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            skip.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
            skip.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// Gone from the screen but still on it as far as AppKit knows, so it doesn't
    /// count as the last window closed.
    func makeTransparent() {
        bar.stopAnimation(nil)
        window.ignoresMouseEvents = true
        window.alphaValue = 0
    }

    func close() {
        bar.stopAnimation(nil)
        window.close()
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

    @objc private func skipPressed() {
        onSkip?()
    }
}
#endif
