import Foundation

public struct HistoryRecord: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pasted
        /// Cleanup failed; the raw transcript was pasted.
        case pastedRaw
        /// Could not paste; left on the clipboard.
        case copiedOnly
        case failed
    }

    public var id = UUID()
    public var timestamp: Date
    public var rawTranscript: String
    public var cleanedTranscript: String?
    public var appName: String?
    public var bundleID: String?
    public var provider: String
    public var cleanupMode: CleanupMode
    /// Recording stop → paste, in milliseconds.
    public var latencyMs: Int
    public var status: Status
    public var errorMessage: String?
    /// The text as the user fixed it afterwards in the history.
    public var correctedText: String?

    /// What was (or would have been) inserted.
    public var insertedText: String { cleanedTranscript ?? rawTranscript }
    /// The latest version of the text: the user's correction, else what was inserted.
    public var finalText: String { correctedText ?? insertedText }
}

/// Recent dictations, newest first. Audio is never stored.
@MainActor
@Observable
public final class HistoryStore {
    public static let limit = 200

    public private(set) var records: [HistoryRecord]
    @ObservationIgnored private let file: JSONFileStore<[HistoryRecord]>

    public convenience init() {
        self.init(file: .appSupport("history.json"))
    }

    init(file: JSONFileStore<[HistoryRecord]>) {
        self.file = file
        records = file.load() ?? []
    }

    public func append(_ record: HistoryRecord) {
        records.insert(record, at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
        file.save(records)
    }

    public func update(_ record: HistoryRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        file.save(records)
    }

    public func removeAll() {
        records.removeAll()
        file.save(records)
    }
}
