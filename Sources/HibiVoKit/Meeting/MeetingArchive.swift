import Foundation

/// One saved meeting: its transcript and, when Claude wrote them, its minutes.
public struct MeetingRecord: Identifiable, Hashable, Sendable {
    /// The start stamp shared by both files, e.g. `2026-09-27_14-00-05`.
    public var id: String
    public var startedAt: Date
    public var transcriptURL: URL?
    public var minutesURL: URL?

    /// The title Claude gave the minutes, or nil when there are none or they fell back to `議事録`.
    public var title: String? {
        guard let minutesURL else { return nil }
        let name = minutesURL.deletingPathExtension().lastPathComponent.dropFirst(id.count + 1)
        return name.isEmpty || name == "議事録" ? nil : String(name)
    }

    /// The file worth opening first.
    public var primaryURL: URL? { minutesURL ?? transcriptURL }
}

/// The meetings saved in the Meetings folder, newest first. The files are the source of truth, so
/// a file the user deletes or renames in Finder simply drops out on the next refresh.
@MainActor
@Observable
public final class MeetingArchive {
    public private(set) var records: [MeetingRecord] = []
    @ObservationIgnored private let directory: URL

    public init(directory: URL = MeetingController.defaultDirectory) {
        self.directory = directory
        refresh()
    }

    public func refresh() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let records = Self.records(fileNames: names, in: directory)
        if records != self.records { self.records = records }
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
