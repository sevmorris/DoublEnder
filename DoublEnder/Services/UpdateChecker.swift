import AppKit

actor UpdateChecker {

    enum Result {
        case upToDate(version: String)
        case available(version: String, downloadURL: URL, releaseURL: URL)
        case error(String)
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlUrl: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadUrl = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case assets
        }
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

            let latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            guard !currentVersion.isEmpty else { return .error("Could not read app version.") }

            guard let releaseURL = URL(string: release.htmlUrl)
                    ?? URL(string: "https://github.com/sevmorris/DoublEnder/releases") else {
                return .error("Invalid release URL in GitHub response.")
            }
            let downloadURL = release.assets.first(where: { $0.name.hasSuffix(".dmg") })
                .flatMap { URL(string: $0.browserDownloadUrl) }
                ?? releaseURL

            if latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending {
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
    }

    /// Cloud build: read a small JSON manifest published next to the DMG
    /// instead of GitHub, so clients are never pointed at the public app.
    /// release-cloud.sh writes cloud-latest.json on every release.
    private func checkCloud() async -> Result {
        guard let manifestURL = URL(string:
            "https://storage.googleapis.com/doublender-downloads/cloud-latest.json") else {
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
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            guard !currentVersion.isEmpty else { return .error("Could not read app version.") }
            guard let downloadURL = URL(string: manifest.url) else {
                return .error("Invalid download URL in manifest.")
            }

            if manifest.version.compare(currentVersion, options: .numeric) == .orderedDescending {
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
@MainActor
func checkForUpdates(silent: Bool = false) async {
    let result = await UpdateChecker().check()

    switch result {
    case .upToDate(let version):
        guard !silent else { return }
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "DoublEnder \(version) is the latest version."
        alert.addButton(withTitle: "OK")
        alert.runModal()

    case .available(let version, let downloadURL, let releaseURL):
        let alert = NSAlert()
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

    case .error(let message):
        guard !silent else { return }
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
