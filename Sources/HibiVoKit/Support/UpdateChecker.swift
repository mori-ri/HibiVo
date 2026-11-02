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

/// Asks GitHub for the latest published release and remembers whether it is newer than this build.
/// It only tells the user: nothing is downloaded or installed, and the link it offers is a fixed URL.
@MainActor
@Observable
public final class UpdateChecker {
    /// Returns the latest release's tag.
    public typealias FetchLatest = @Sendable () async throws -> String

    /// The newer version to mention, if any.
    public private(set) var availableVersion: String?

    private static let interval: Duration = .seconds(24 * 60 * 60)
    /// Launch at login usually runs before the network is up, so a failure is retried soon.
    private static let retryInterval: Duration = .seconds(60 * 60)

    @ObservationIgnored private let current: AppVersion?
    @ObservationIgnored private let isEnabled: @MainActor () -> Bool
    @ObservationIgnored private let fetchLatest: FetchLatest
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "updates")

    public init(
        currentVersion: String?, isEnabled: @escaping @MainActor () -> Bool,
        fetchLatest: @escaping FetchLatest = UpdateChecker.fetchLatestTag
    ) {
        current = currentVersion.flatMap(AppVersion.init)
        self.isEnabled = isEnabled
        self.fetchLatest = fetchLatest
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
        guard isEnabled(), let current else {
            availableVersion = nil
            return true
        }
        do {
            let tag = try await fetchLatest()
            // The setting may have been turned off while the request was running.
            guard isEnabled(), let latest = AppVersion(tag) else {
                availableVersion = nil
                return true
            }
            availableVersion = latest > current ? latest.text : nil
            return true
        } catch {
            log.notice("Update check failed")
            return false
        }
    }

    private struct Release: Decodable {
        var tagName: String
        enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
    }

    /// GitHub leaves drafts and pre-releases out of this endpoint.
    @Sendable public static func fetchLatestTag() async throws -> String {
        var request = URLRequest(url: ProjectLinks.latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("HibiVo", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Release.self, from: data).tagName
    }
}
