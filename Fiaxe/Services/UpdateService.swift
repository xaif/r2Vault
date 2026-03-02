import Foundation

struct GitHubRelease: Decodable {
    let tagName: String
    let htmlUrl: String
    let body: String?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case body
        case assets
    }

    /// The browser download URL for the first .dmg asset, if present.
    var dmgDownloadURL: URL? {
        assets.first(where: { $0.name.hasSuffix(".dmg") }).flatMap { URL(string: $0.browserDownloadUrl) }
    }
}

struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}

enum UpdateService {
    private static let apiURL = URL(string: "https://api.github.com/repos/xaif/r2Vault/releases/latest")!

    /// Fetches the latest release from GitHub and returns it if it is newer than the running version.
    static func checkForUpdate() async throws -> GitHubRelease? {
        var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, _) = try await URLSession.shared.data(for: request)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        let latestVersion = release.tagName.trimmingCharacters(in: .init(charactersIn: "v"))
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

        if latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending {
            return release
        }
        return nil
    }
}
