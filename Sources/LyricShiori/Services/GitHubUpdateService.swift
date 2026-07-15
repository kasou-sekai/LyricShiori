import AppKit
import Foundation
import Observation

/// Checks the project's public GitHub releases and installs the release
/// archive in a separate process, so the running application can be replaced.
@MainActor
@Observable
final class GitHubUpdateService {
    static let releasesURL = URL(string: "https://api.github.com/repos/kasou-sekai/LyricShiori/releases/latest")!
    static let requiredAssetPrefix = "LyricShiori-"

    private(set) var status: UpdateStatus = .idle
    private(set) var availableUpdate: AvailableUpdate?
    private(set) var releaseNotes: String?

    @ObservationIgnored private var installerProcess: Process?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .preparingInstallation:
            true
        default:
            false
        }
    }

    func checkForUpdates() async {
        guard !isBusy else { return }

        status = .checking
        availableUpdate = nil
        releaseNotes = nil

        do {
            var request = URLRequest(url: Self.releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("LyricShiori update checker", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw UpdateError.invalidResponse
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw UpdateError.httpStatus(httpResponse.statusCode)
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard Self.isVersion(release.tagName, newerThan: currentVersion) else {
                status = .upToDate
                return
            }
            guard let asset = release.assets.first(where: Self.isSupportedInstallerAsset) else {
                throw UpdateError.noSupportedAsset(release.tagName)
            }

            let update = AvailableUpdate(
                version: release.tagName,
                title: release.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? release.tagName,
                assetURL: asset.downloadURL,
                assetName: asset.name
            )
            availableUpdate = update
            releaseNotes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            status = .updateAvailable
        } catch is CancellationError {
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Downloads the release archive and hands it to a short-lived helper
    /// process. The helper owns cleanup after either a successful installation
    /// or an error, because the app must quit before it can be overwritten.
    func downloadAndInstallAvailableUpdate() async {
        guard let update = availableUpdate, !isBusy else { return }

        status = .downloading
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LyricShiori-update-\(UUID().uuidString).zip")

        var temporaryDownloadURL: URL?
        do {
            var request = URLRequest(url: update.assetURL)
            request.setValue("LyricShiori updater", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 120

            let (downloadURL, response) = try await URLSession.shared.download(for: request)
            temporaryDownloadURL = downloadURL
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw UpdateError.invalidDownloadResponse
            }

            try FileManager.default.moveItem(at: downloadURL, to: archiveURL)
            temporaryDownloadURL = nil
            guard (try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
                throw UpdateError.emptyDownload
            }

            status = .preparingInstallation
            try launchInstaller(for: archiveURL)
            // The helper deletes the archive after it has either installed the
            // app or reported an installation error. Do not delete it here.
            NSApplication.shared.terminate(nil)
        } catch {
            if let temporaryDownloadURL {
                try? FileManager.default.removeItem(at: temporaryDownloadURL)
            }
            try? FileManager.default.removeItem(at: archiveURL)
            status = .failed(error.localizedDescription)
        }
    }

    private func launchInstaller(for archiveURL: URL) throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LyricShiori-install-\(UUID().uuidString).command")
        do {
            try Self.installerScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path, archiveURL.path, String(ProcessInfo.processInfo.processIdentifier)]
            try process.run()
            installerProcess = process
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
            throw error
        }
    }

    private static func isSupportedInstallerAsset(_ asset: GitHubRelease.Asset) -> Bool {
        asset.name.hasPrefix(requiredAssetPrefix)
            && asset.name.lowercased().hasSuffix(".zip")
            && asset.downloadURL.scheme == "https"
            && (asset.downloadURL.host == "github.com" || asset.downloadURL.host == "objects.githubusercontent.com")
    }

    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let candidateComponents = versionComponents(candidate)
        let currentComponents = versionComponents(current)
        let count = max(candidateComponents.count, currentComponents.count)
        for index in 0..<count {
            let candidateValue = candidateComponents.indices.contains(index) ? candidateComponents[index] : 0
            let currentValue = currentComponents.indices.contains(index) ? currentComponents[index] : 0
            if candidateValue != currentValue {
                return candidateValue > currentValue
            }
        }
        return false
    }

    private nonisolated static func versionComponents(_ value: String) -> [Int] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let stableVersion = trimmed.split(separator: "-", maxSplits: 1).first.map(String.init) ?? trimmed
        return stableVersion.split(separator: ".").compactMap { Int($0) }
    }

    private static let installerScript = #"""
    #!/bin/bash
    set -uo pipefail

    archive="$1"
    parent_pid="$2"
    work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LyricShiori-update.XXXXXX")" || {
      /bin/rm -rf "$archive" "$0"
      exit 1
    }
    script_path="$0"

    cleanup() {
      /bin/rm -rf "$archive" "$work_dir" "$script_path"
    }
    fail() {
      /usr/bin/osascript -e 'display notification "The downloaded update was removed. Please try again." with title "LyricShiori update failed"' >/dev/null 2>&1 || true
      exit 1
    }
    trap cleanup EXIT

    while /bin/kill -0 "$parent_pid" 2>/dev/null; do
      /bin/sleep 0.25
    done

    /usr/bin/ditto -x -k "$archive" "$work_dir" || fail
    app_path="$(/usr/bin/find "$work_dir" -maxdepth 2 -type d -name 'LyricShiori.app' -print -quit)"
    [[ -n "$app_path" ]] || fail
    bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null)"
    [[ "$bundle_identifier" == "dev.lyricshiori.app" ]] || fail
    /usr/bin/codesign --verify --deep --strict "$app_path" || fail

    destination="/Applications/LyricShiori.app"
    if [[ -w "/Applications" ]] || [[ -w "$destination" ]]; then
      /bin/rm -rf "$destination" || fail
      /usr/bin/ditto "$app_path" "$destination" || fail
    else
      /usr/bin/osascript - "$app_path" "$destination" <<'APPLESCRIPT' || fail
    on run argv
      set sourcePath to item 1 of argv
      set destinationPath to item 2 of argv
      do shell script "/bin/rm -rf " & quoted form of destinationPath & " && /usr/bin/ditto " & quoted form of sourcePath & " " & quoted form of destinationPath with administrator privileges
    end run
    APPLESCRIPT
    fi

    /usr/bin/open "$destination" || fail
    """#
}

struct AvailableUpdate: Equatable {
    let version: String
    let title: String
    fileprivate let assetURL: URL
    let assetName: String
}

enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable
    case downloading
    case preparingInstallation
    case failed(String)

    var message: String {
        switch self {
        case .idle:
            ""
        case .checking:
            "Checking GitHub for updates…"
        case .upToDate:
            "You’re up to date."
        case .updateAvailable:
            "A new version is ready to install."
        case .downloading:
            "Downloading update…"
        case .preparingInstallation:
            "Preparing installation…"
        case .failed(let message):
            "Update check failed: \(message)"
        }
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let downloadURL: URL

        private enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case assets
    }
}

private enum UpdateError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case noSupportedAsset(String)
    case invalidDownloadResponse
    case emptyDownload

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "GitHub returned an invalid response."
        case .httpStatus(let status):
            "GitHub returned HTTP \(status)."
        case .noSupportedAsset(let version):
            "Release \(version) has no LyricShiori macOS update package."
        case .invalidDownloadResponse:
            "The update download returned an invalid response."
        case .emptyDownload:
            "The update download was empty."
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
