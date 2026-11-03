import Foundation
import OSLog
import Observation

/// A release version such as `0.6.0` or `v0.6.0-beta.1`. Anything else is rejected, so text from the network
/// is never shown as is. Pre-releases sort before their release; they aren't ordered among themselves.
public struct AppVersion: Comparable, Sendable {
    public let text: String
    private let numbers: [Int]
    private let isPrerelease: Bool

    public init?(_ string: String) {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        guard trimmed.wholeMatch(of: /[0-9]{1,6}(\.[0-9]{1,6}){0,2}(-[0-9A-Za-z.]+)?/) != nil else { return nil }
        let parts = trimmed.split(separator: "-", maxSplits: 1)
        let numbers = parts[0].split(separator: ".").compactMap { Int($0) }
        self.numbers = numbers + Array(repeating: 0, count: 3 - numbers.count)
        isPrerelease = parts.count > 1
        text = trimmed
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.numbers == rhs.numbers && lhs.isPrerelease == rhs.isPrerelease
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.numbers == rhs.numbers
            ? lhs.isPrerelease && !rhs.isPrerelease : lhs.numbers.lexicographicallyPrecedes(rhs.numbers)
    }
}

/// A release as GitHub's API lists it.
public struct PublishedRelease: Decodable, Sendable {
    public var tagName: String
    public var body: String?
    public var publishedAt: Date?
    public var prerelease: Bool
    public var draft: Bool

    public init(
        tagName: String, body: String? = nil, publishedAt: Date? = nil, prerelease: Bool = false, draft: Bool = false
    ) {
        self.tagName = tagName
        self.body = body
        self.publishedAt = publishedAt
        self.prerelease = prerelease
        self.draft = draft
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case publishedAt = "published_at"
        case prerelease
        case draft
    }
}

/// Asks GitHub for the published releases, remembers whether the latest is newer than this build, and keeps their
/// notes for the News page. Nothing is installed: the download link is a fixed URL to the latest release's disk image,
/// opened in the browser so the file is quarantined and checked by Gatekeeper like any other download.
@MainActor
@Observable
public final class UpdateChecker {
    /// Returns the repository's releases, newest first.
    public typealias FetchReleases = @Sendable () async throws -> [PublishedRelease]

    /// The newer version to mention, if any.
    public private(set) var availableVersion: String?
    /// Stable releases, newest first, for the News page.
    public private(set) var notes: [ReleaseNote] = []
    public private(set) var isLoading = false
    /// Whether the last request failed, so the News page can offer to try again.
    public private(set) var loadFailed = false
    /// This build's version; nil under `swift run`.
    public let currentVersion: AppVersion?

    /// How many releases the News page shows.
    static let noteLimit = 5
    private static let interval: Duration = .seconds(24 * 60 * 60)
    /// Launch at login usually runs before the network is up, so a failure is retried soon.
    private static let retryInterval: Duration = .seconds(60 * 60)

    @ObservationIgnored private let isEnabled: @MainActor () -> Bool
    @ObservationIgnored private let fetchReleases: FetchReleases
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "updates")

    public init(
        currentVersion: String?, isEnabled: @escaping @MainActor () -> Bool,
        fetchReleases: @escaping FetchReleases = UpdateChecker.fetchPublishedReleases
    ) {
        self.currentVersion = currentVersion.flatMap(AppVersion.init)
        self.isEnabled = isEnabled
        self.fetchReleases = fetchReleases
    }

    /// Checks now and then once a day for as long as the app runs.
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let succeeded = await self?.check() else { return }
                try? await Task.sleep(for: succeeded ? Self.interval : Self.retryInterval)
            }
        }
    }

    /// Returns false when the check couldn't be completed. Turning the setting off clears any notice.
    @discardableResult
    public func check() async -> Bool {
        guard isEnabled(), currentVersion != nil else {
            availableVersion = nil
            return true
        }
        guard let releases = await fetch() else { return false }
        apply(releases)
        return true
    }

    /// Loads the notes for the News page. Unlike `check`, it asks even when the automatic check is off, so it is
    /// only called when the user asks; the update notice still follows the setting.
    public func loadNotes() async {
        guard let releases = await fetch() else { return }
        apply(releases)
    }

    /// Whether the newest release's notes are newer than the ones the News page last showed.
    /// Never having opened the page counts as unread, so people updating from a version without it find it.
    public func hasUnreadNotes(lastSeen: String?) -> Bool {
        guard let newest = notes.first?.version else { return false }
        guard let seen = lastSeen.flatMap(AppVersion.init) else { return true }
        return newest > seen
    }

    private func fetch() async -> [PublishedRelease]? {
        isLoading = true
        defer { isLoading = false }
        do {
            let releases = try await fetchReleases()
            loadFailed = false
            return releases
        } catch {
            loadFailed = true
            log.notice("Update check failed")
            return nil
        }
    }

    private func apply(_ releases: [PublishedRelease]) {
        notes = Self.notes(from: releases)
        // The setting may have been turned off while the request was running.
        guard isEnabled(), let currentVersion, let newest = notes.first?.version, newest > currentVersion else {
            availableVersion = nil
            return
        }
        availableVersion = newest.text
    }

    /// Stable releases whose tag is a version, newest first. Drafts and pre-releases are left out, as GitHub's
    /// "latest release" (which the download link points to) leaves them out.
    static func notes(from releases: [PublishedRelease]) -> [ReleaseNote] {
        let notes = releases.filter { !$0.draft && !$0.prerelease }.compactMap { release -> ReleaseNote? in
            guard let version = AppVersion(release.tagName) else { return nil }
            let blocks = ReleaseNotes.blocks(from: release.body ?? "")
            return ReleaseNote(version: version, publishedAt: release.publishedAt, blocks: blocks)
        }
        return Array(notes.sorted { $0.version > $1.version }.prefix(noteLimit))
    }

    @Sendable public static func fetchPublishedReleases() async throws -> [PublishedRelease] {
        var request = URLRequest(url: ProjectLinks.releasesAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("HibiVo", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PublishedRelease].self, from: data)
    }
}
