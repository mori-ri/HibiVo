import Foundation

/// One saved meeting: its transcript and, when Claude wrote them, its minutes.
public struct MeetingRecord: Identifiable, Hashable, Sendable {
    /// The start stamp shared by both files, e.g. `2026-09-27_14-00-05`.
    public var id: String
    public var startedAt: Date
    public var transcriptURL: URL?
    public var minutesURL: URL?
    /// The title and tags given during the meeting, from the files' front matter.
    public var metadata = MeetingMetadata()

    /// The title given during the meeting, else the one Claude gave the minutes; nil when there is
    /// neither or the minutes fell back to `議事録`.
    public var title: String? {
        if !metadata.title.isEmpty { return metadata.title }
        guard let minutesURL else { return nil }
        let name = minutesURL.deletingPathExtension().lastPathComponent.dropFirst(id.count + 1)
        return name.isEmpty || name == "議事録" ? nil : String(name)  // no-l10n
    }

    /// The file worth opening first.
    public var primaryURL: URL? { minutesURL ?? transcriptURL }
}

/// The meetings saved in the chosen folder and the built-in one, newest first. The files are the
/// source of truth, so a file the user deletes or renames in Finder simply drops out on the next refresh.
@MainActor
@Observable
public final class MeetingArchive {
    public private(set) var records: [MeetingRecord] = []
    /// The chosen folder first; the built-in one also holds meetings saved before the user chose one.
    @ObservationIgnored private let directories: @MainActor () -> [URL]
    /// Front matter already read, keyed by file and modification date, so a refresh only reads changed files.
    @ObservationIgnored private var metadataCache: [URL: (modified: Date?, metadata: MeetingMetadata)] = [:]

    public init(directories: @escaping @MainActor () -> [URL] = { [MeetingController.defaultDirectory] }) {
        self.directories = directories
        refresh()
    }

    public func refresh() {
        var seen: Set<URL> = []
        let listings = directories().filter { seen.insert($0.standardizedFileURL).inserted }.map {
            (directory: $0, names: (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [])
        }
        var cache: [URL: (modified: Date?, metadata: MeetingMetadata)] = [:]
        let records = Self.records(listings).map { record in
            // The transcript holds the front matter; the minutes repeat it in case the transcript was deleted.
            guard let url = record.transcriptURL ?? record.minutesURL else { return record }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let metadata: MeetingMetadata
            if let cached = metadataCache[url], cached.modified == modified, modified != nil {
                metadata = cached.metadata
            } else {
                metadata = MeetingMetadata.read(from: url)
            }
            cache[url] = (modified, metadata)
            var record = record
            record.metadata = metadata
            return record
        }
        metadataCache = cache
        if records != self.records { self.records = records }
    }

    /// Tags used in earlier meetings, most recent first, for quick picking.
    public func recentTags(excluding: [String] = [], limit: Int = 8) -> [String] {
        MeetingMetadata.recentTags(records, excluding: excluding, limit: limit)
    }

    /// Merges several folders; a meeting found in more than one keeps the first folder's files.
    nonisolated static func records(_ listings: [(directory: URL, names: [String])], timeZone: TimeZone = .current)
        -> [MeetingRecord]
    {
        var ids: Set<String> = []
        return listings.flatMap { records(fileNames: $0.names, in: $0.directory, timeZone: timeZone) }
            .filter { ids.insert($0.id).inserted }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Pairs `<stamp>.md` with `<stamp>_<title>.md`. Files that don't start with a stamp are ignored.
    nonisolated static func records(fileNames: [String], in directory: URL, timeZone: TimeZone = .current)
        -> [MeetingRecord]
    {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stampLength = "yyyy-MM-dd_HH-mm-ss".count

        var byStamp: [String: MeetingRecord] = [:]
        for name in fileNames where name.hasSuffix(".md") {
            let base = String(name.dropLast(3))
            let stamp = String(base.prefix(stampLength))
            guard let date = formatter.date(from: stamp) else { continue }
            let rest = base.dropFirst(stampLength)
            let url = directory.appending(path: name)
            var record = byStamp[stamp] ?? MeetingRecord(id: stamp, startedAt: date)
            if rest.isEmpty {
                record.transcriptURL = url
            } else if rest.hasPrefix("_") {
                // Several minutes for one meeting shouldn't happen; keep the first by name for stability.
                if record.minutesURL.map({ name < $0.lastPathComponent }) ?? true { record.minutesURL = url }
            } else {
                continue
            }
            byStamp[stamp] = record
        }
        return byStamp.values.sorted { $0.startedAt > $1.startedAt }
    }
}
