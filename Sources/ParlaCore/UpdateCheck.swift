import Foundation

/// GitHub Releases update check. Pure version logic + a throttled fetch; the
/// menu wiring in Updater.swift stays thin. A failure (network, rate limit, no
/// releases) is an outcome, never a nag or a crash.
public enum UpdateCheck {
    static let latestURL = URL(string: "https://api.github.com/repos/wannabeepolymath/parla/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/wannabeepolymath/parla/releases/latest")!
    static let throttleKey = "Parla.updateCheck.lastDate"

    /// Hidden override for the releases/latest URL, so two locally signed
    /// builds can be tested against each other before anything is published.
    static let feedURLKey = "Parla.updateCheck.feedURL"

    /// The subset of the releases/latest payload we care about.
    struct Release: Decodable {
        let tagName: String
        let htmlURL: String?
        let assets: [Asset]?
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", htmlURL = "html_url", assets }
        struct Asset: Decodable {
            let name: String
            let downloadURL: String
            enum CodingKeys: String, CodingKey { case name, downloadURL = "browser_download_url" }
        }
    }

    /// A newer release to point the user at.
    public struct Update: Equatable, Sendable {
        public let version: String // display form, e.g. "v0.2.0"
        public let url: URL
        /// The release's `Parla-<version>.dmg`; nil ⇒ only the browser can update.
        public let dmgURL: URL?
    }

    /// Only the manual check shows `.upToDate` and `.failed`; the scheduled one
    /// stays silent on both.
    public enum Outcome: Equatable, Sendable { case available(Update), upToDate, throttled, failed }

    static func bare(_ tag: String) -> String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }

    /// The asset named exactly `Parla-<version>.dmg` — make-dmg.sh's name.
    static func dmgURL(in release: Release) -> URL? {
        let name = "Parla-\(bare(release.tagName)).dmg"
        return release.assets?.first { $0.name == name }.flatMap { URL(string: $0.downloadURL) }
    }

    /// Numeric, component-wise: "0.10.0" > "0.9.0", "0.1" == "0.1.0". A leading
    /// "v" is stripped; non-numeric components (prerelease garbage) parse as 0
    /// rather than crashing.
    static func components(_ version: String) -> [Int] {
        let v = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return v.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// True when `remote` is a strictly newer version than `current`.
    public static func isNewer(remote: String, current: String) -> Bool {
        let a = components(remote), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Fetch the latest release and decide if it's newer than `currentVersion`.
    /// Throttled to once per 24h via UserDefaults unless `force` (the manual
    /// check); only a successful fetch stamps the timestamp. Unbundled
    /// (`swift run`, no version) reads as `.failed`.
    public static func check(currentVersion: String?, force: Bool = false,
                             defaults: UserDefaults = .standard,
                             now: Date = Date(),
                             fetch: (URLRequest) async throws -> (Data, URLResponse) = {
                                 try await URLSession.shared.data(for: $0)
                             }) async -> Outcome {
        guard let currentVersion else { return .failed }
        if !force, let last = defaults.object(forKey: throttleKey) as? Date,
           now.timeIntervalSince(last) < 24 * 60 * 60 { return .throttled }
        let feed = defaults.string(forKey: feedURLKey).flatMap(URL.init(string:)) ?? latestURL
        var request = URLRequest(url: feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await fetch(request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else { return .failed }
        defaults.set(now, forKey: throttleKey)
        guard isNewer(remote: release.tagName, current: currentVersion) else { return .upToDate }
        return .available(Update(version: "v" + bare(release.tagName),
                                 url: release.htmlURL.flatMap(URL.init(string:)) ?? releasesPage,
                                 dmgURL: dmgURL(in: release)))
    }
}
