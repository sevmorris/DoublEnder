import AppKit

actor UpdateChecker {

    /// The running app's marketing version string, read once per check.
    /// A computed property avoids the repeated `infoDictionary` lookup that
    /// appeared in both the public and Cloud branches (m16).
    private var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Strip pre-release suffixes (`-rc1`, `-beta.2`, etc.) so that a tagged
    /// beta on GitHub never triggers an "update available" prompt for
    /// production users (m4). Only the numeric `major.minor.patch` part is
    /// used for comparison.
    private static func numericVersion(_ raw: String) -> String {
        VersionFormatting.numericVersion(raw)
    }

    enum Result {
        case upToDate(version: String)
        case available(version: String, downloadURL: URL, releaseURL: URL)
        /// Newer than this build, but it needs a newer macOS than this Mac has.
        case needsNewerMacOS(version: String, minimum: String, installed: String)
        case error(String)
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlUrl: String
        /// The release notes, which carry the minimum-macos marker.
        let body: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case body
        }
    }

    /// The macOS a release says it needs. release.sh ends every release's notes
    /// with `<!-- minimum-macos: 15.0 -->`, read from the built app's
    /// LSMinimumSystemVersion; GitHub does not render the comment. nil when there
    /// is no marker: a release from before it existed, which runs on every macOS
    /// this build does.
    nonisolated static func minimumMacOS(inReleaseNotes notes: String?) -> OperatingSystemVersion? {
        guard let notes,
              let start = notes.range(of: "<!-- minimum-macos:"),
              let end = notes[start.upperBound...].range(of: "-->") else { return nil }
        return macOSVersion(String(notes[start.upperBound..<end.lowerBound]))
    }

    /// "15", "15.0" or "15.2.1" as a version; nil for anything else.
    nonisolated static func macOSVersion(_ string: String) -> OperatingSystemVersion? {
        let fields = string.trimmingCharacters(in: .whitespaces)
            .split(separator: ".", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { Int($0) }
        guard (1...3).contains(fields.count), numbers.count == fields.count else { return nil }
        return OperatingSystemVersion(majorVersion: numbers[0],
                                      minorVersion: numbers.count > 1 ? numbers[1] : 0,
                                      patchVersion: numbers.count > 2 ? numbers[2] : 0)
    }

    /// True when a Mac running `os` meets `minimum`.
    nonisolated static func runs(on os: OperatingSystemVersion, given minimum: OperatingSystemVersion) -> Bool {
        (os.majorVersion, os.minorVersion, os.patchVersion)
            >= (minimum.majorVersion, minimum.minorVersion, minimum.patchVersion)
    }

    /// "15.0", or "15.2.1" when there is a patch number.
    nonisolated static func describe(_ version: OperatingSystemVersion) -> String {
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion > 0 ? "\(base).\(version.patchVersion)" : base
    }

    func check() async -> Result {
        #if GCS_ENABLED
        return await checkCloud()
        #else
        guard let apiURL = URL(string: "https://api.github.com/repos/sevmorris/DoublEnder/releases/latest") else {
            return .error("Invalid update URL.")
        }

        do {
            var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard statusCode == 200 else {
                return .error("Update check failed (HTTP \(statusCode)). Try again later.")
            }

            let release = try JSONDecoder().decode(Release.self, from: data)

            let latestVersion = Self.numericVersion(release.tagName)
            let currentVersion = installedVersion
            guard !currentVersion.isEmpty else { return .error("Could not read app version.") }

            guard let releaseURL = URL(string: release.htmlUrl)
                    ?? URL(string: "https://github.com/sevmorris/DoublEnder/releases") else {
                return .error("Invalid release URL in GitHub response.")
            }
            // Always use the GCS permalink so the user gets the current
            // latest build at click-time, not a stale version-pinned URL.
            let downloadURL = URL(string: "https://storage.googleapis.com/doublender-downloads/DoublEnder.dmg")!

            if latestVersion.compare(Self.numericVersion(currentVersion), options: .numeric) == .orderedDescending {
                // A release this Mac cannot run is not an update for it: its DMG
                // would replace a working app with one that will not open.
                if let minimum = Self.minimumMacOS(inReleaseNotes: release.body),
                   !Self.runs(on: ProcessInfo.processInfo.operatingSystemVersion, given: minimum) {
                    return .needsNewerMacOS(version: latestVersion, minimum: Self.describe(minimum),
                                            installed: currentVersion)
                }
                return .available(version: latestVersion, downloadURL: downloadURL, releaseURL: releaseURL)
            } else {
                return .upToDate(version: currentVersion)
            }

        } catch {
            return .error(error.localizedDescription)
        }
        #endif
    }

    #if GCS_ENABLED
    private struct CloudManifest: Decodable {
        let version: String
        let url: String
        /// Written by release-cloud-lib.sh from the built app; absent from
        /// manifests published before it.
        let minimumSystemVersion: String?
    }

    /// Cloud build: read a small JSON manifest published next to the DMG
    /// instead of GitHub, so clients are never pointed at the public app.
    /// release-cloud.sh writes cloud-latest.json on every release.
    ///
    /// The manifest URL is read from the bundle's `UpdateManifestURL` Info.plist
    /// key (set via `UPDATE_MANIFEST_URL` in project.cloud.yml). Falls back to
    /// the standard Cloud manifest for legacy builds that pre-date the key.
    private func checkCloud() async -> Result {
        let defaultManifestURL = "https://storage.googleapis.com/doublender-downloads/cloud-latest.json"
        let urlString = (Bundle.main.infoDictionary?["UpdateManifestURL"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        } ?? defaultManifestURL
        guard let manifestURL = URL(string: urlString) else {
            return .error("Invalid update URL.")
        }
        do {
            var request = URLRequest(url: manifestURL,
                                     cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard statusCode == 200 else {
                return .error("Update check failed (HTTP \(statusCode)). Try again later.")
            }

            let manifest = try JSONDecoder().decode(CloudManifest.self, from: data)
            let currentVersion = installedVersion
            guard !currentVersion.isEmpty else { return .error("Could not read app version.") }
            guard let downloadURL = URL(string: manifest.url) else {
                return .error("Invalid download URL in manifest.")
            }

            if Self.numericVersion(manifest.version).compare(Self.numericVersion(currentVersion), options: .numeric) == .orderedDescending {
                // As for the public build: a guest's Mac below the minimum is told
                // so, rather than offered a DMG whose app will not open there.
                if let minimum = manifest.minimumSystemVersion.flatMap(Self.macOSVersion),
                   !Self.runs(on: ProcessInfo.processInfo.operatingSystemVersion, given: minimum) {
                    return .needsNewerMacOS(version: manifest.version, minimum: Self.describe(minimum),
                                            installed: currentVersion)
                }
                return .available(version: manifest.version,
                                  downloadURL: downloadURL,
                                  releaseURL: downloadURL)
            } else {
                return .upToDate(version: currentVersion)
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }
    #endif
}

/// Show an update dialog. When `silent` is true (launch check), only prompt if
/// an update is actually available — don't bother the user with "you're up to date".
/// Force secondary alerts into the dark "aqua" appearance regardless of
/// the system setting — keeps every non-primary surface on the same dark
/// palette as the SwiftUI dialogs.
@MainActor
private func makeLightAlert() -> NSAlert {
    let alert = NSAlert()
    alert.window.appearance = NSAppearance(named: .darkAqua)
    return alert
}

@MainActor
func checkForUpdates(silent: Bool = false) async {
    let result = await UpdateChecker().check()

    switch result {
    case .upToDate(let version):
        guard !silent else { return }
        let alert = makeLightAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "DoublEnder \(version) is the latest version."
        alert.addButton(withTitle: "OK")
        alert.runModal()

    case .available(let version, let downloadURL, let releaseURL):
        let alert = makeLightAlert()
        alert.messageText = "Update Available"
        #if GCS_ENABLED
        // Cloud has no GitHub release page; one Download button only.
        alert.informativeText = "DoublEnder Cloud \(version) is available."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(downloadURL)
        }
        _ = releaseURL
        #else
        alert.informativeText = "DoublEnder \(version) is available."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(downloadURL)
        } else if response == .alertSecondButtonReturn {
            NSWorkspace.shared.open(releaseURL)
        }
        #endif

    case .needsNewerMacOS(let version, let minimum, let installed):
        // Nothing this Mac can install, so the check at launch says nothing.
        guard !silent else { return }
        #if GCS_ENABLED
        let name = "DoublEnder Cloud"
        #else
        let name = "DoublEnder"
        #endif
        let alert = makeLightAlert()
        alert.messageText = "\(name) \(version) needs macOS \(minimum)"
        alert.informativeText = "This Mac has macOS \(UpdateChecker.describe(ProcessInfo.processInfo.operatingSystemVersion)), "
            + "so \(name) \(installed) is the newest version it can run."
        alert.addButton(withTitle: "OK")
        alert.runModal()

    case .error(let message):
        guard !silent else { return }
        let alert = makeLightAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
