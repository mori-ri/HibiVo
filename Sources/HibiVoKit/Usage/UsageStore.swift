import Foundation

/// Speech-to-text audio sent for one provider/model on one day.
public struct TranscriptionUsage: Codable, Hashable, Sendable {
    public var provider: String
    public var model: String
    public var seconds: Double

    func isSameModel(as other: TranscriptionUsage) -> Bool {
        provider == other.provider && model == other.model
    }
}

/// Cleanup requests that reported token usage, for one provider/model on one day.
public struct CleanupUsage: Codable, Hashable, Sendable {
    public var provider: String
    public var model: String
    /// AWS Region for Bedrock, whose prices differ by Region. nil for other providers.
    public var region: String?
    public var requests: Int
    public var tokens: TokenUsage

    public init(provider: String, model: String, region: String? = nil, requests: Int, tokens: TokenUsage) {
        self.provider = provider
        self.model = model
        self.region = region
        self.requests = requests
        self.tokens = tokens
    }

    /// One request's worth of usage for `provider`.
    public init(_ provider: any TextCleanupProvider, model: String, tokens: TokenUsage) {
        self.init(
            provider: provider.id, model: model, region: (provider as? BedrockCleanupProvider)?.region, requests: 1,
            tokens: tokens)
    }

    func isSameModel(as other: CleanupUsage) -> Bool {
        provider == other.provider && model == other.model && region == other.region
    }
}

/// Aggregated usage for one local calendar day. Holds counts only, never text.
public struct DailyUsage: Codable, Hashable, Sendable {
    /// Local calendar day, `yyyy-MM-dd`.
    public var day: String
    /// Dictations that produced text (pasted or copied).
    public var dictations = 0
    /// Meetings whose audio was transcribed.
    public var meetings = 0
    /// Characters of the text that was inserted, and of meeting transcripts.
    public var characters = 0
    /// The part of `characters` that came from meetings.
    public var meetingCharacters = 0
    public var transcription: [TranscriptionUsage] = []
    /// The part of `transcription` that came from meetings, kept per model so its cost can be told apart.
    public var meetingTranscription: [TranscriptionUsage] = []
    public var cleanup: [CleanupUsage] = []

    public init(day: String) {
        self.day = day
    }

    /// Dictations and meetings together.
    public var uses: Int { dictations + meetings }

    // Counts added in later versions are missing from older files.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decode(String.self, forKey: .day)
        dictations = try container.decodeIfPresent(Int.self, forKey: .dictations) ?? 0
        meetings = try container.decodeIfPresent(Int.self, forKey: .meetings) ?? 0
        characters = try container.decodeIfPresent(Int.self, forKey: .characters) ?? 0
        meetingCharacters = try container.decodeIfPresent(Int.self, forKey: .meetingCharacters) ?? 0
        transcription = try container.decodeIfPresent([TranscriptionUsage].self, forKey: .transcription) ?? []
        meetingTranscription =
            try container.decodeIfPresent([TranscriptionUsage].self, forKey: .meetingTranscription) ?? []
        cleanup = try container.decodeIfPresent([CleanupUsage].self, forKey: .cleanup) ?? []
    }

    public var audioSeconds: Double { transcription.reduce(0) { $0 + $1.seconds } }
    public var tokens: TokenUsage { cleanup.reduce(.zero) { $0 + $1.tokens } }
    /// The part of `audioSeconds` that came from meetings.
    public var meetingSeconds: Double { meetingTranscription.reduce(0) { $0 + $1.seconds } }

    /// Only the meetings' share of the day, for pricing it apart. Minutes are written by Claude Code on
    /// the user's subscription, so meetings have no cleanup tokens.
    public var meetingPart: DailyUsage {
        var part = DailyUsage(day: day)
        part.meetings = meetings
        part.characters = meetingCharacters
        part.meetingCharacters = meetingCharacters
        part.transcription = meetingTranscription
        part.meetingTranscription = meetingTranscription
        return part
    }

    /// Everything but the meetings: dictation and its cleanup, and cleanup re-run from the history.
    public var dictationPart: DailyUsage {
        var part = DailyUsage(day: day)
        part.dictations = dictations
        part.characters = characters - meetingCharacters
        part.transcription = transcription.compactMap { usage in
            var usage = usage
            usage.seconds -= meetingTranscription.first { $0.isSameModel(as: usage) }?.seconds ?? 0
            return usage.seconds > 0 ? usage : nil
        }
        part.cleanup = cleanup
        return part
    }

    mutating func add(_ event: UsageEvent) {
        dictations += event.dictations
        meetings += event.meetings
        characters += event.characters
        if event.meetings > 0 { meetingCharacters += event.characters }
        if let stt = event.transcription, stt.seconds > 0 {
            Self.add(stt, to: &transcription)
            if event.meetings > 0 { Self.add(stt, to: &meetingTranscription) }
        }
        if let llm = event.cleanup {
            if let index = cleanup.firstIndex(where: { $0.isSameModel(as: llm) }) {
                cleanup[index].requests += llm.requests
                cleanup[index].tokens = cleanup[index].tokens + llm.tokens
            } else {
                cleanup.append(llm)
            }
        }
    }

    private static func add(_ usage: TranscriptionUsage, to list: inout [TranscriptionUsage]) {
        if let index = list.firstIndex(where: { $0.isSameModel(as: usage) }) {
            list[index].seconds += usage.seconds
        } else {
            list.append(usage)
        }
    }
}

/// One thing that happened, to be added to its day's totals.
public struct UsageEvent: Sendable {
    public var date: Date
    public var dictations = 0
    public var meetings = 0
    public var characters = 0
    public var transcription: TranscriptionUsage?
    public var cleanup: CleanupUsage?

    public init(
        date: Date = Date(), dictations: Int = 0, meetings: Int = 0, characters: Int = 0,
        transcription: TranscriptionUsage? = nil, cleanup: CleanupUsage? = nil
    ) {
        self.date = date
        self.dictations = dictations
        self.meetings = meetings
        self.characters = characters
        self.transcription = transcription
        self.cleanup = cleanup
    }
}

/// Daily usage totals, oldest first. Kept separately from history so the numbers survive the history
/// limit, "clear history" and history being turned off.
@MainActor
@Observable
public final class UsageStore {
    public static let retentionDays = 400

    public private(set) var days: [DailyUsage]
    @ObservationIgnored private let file: JSONFileStore<[DailyUsage]>
    @ObservationIgnored let calendar: Calendar

    public convenience init() {
        self.init(file: .appSupport("usage.json"))
    }

    init(file: JSONFileStore<[DailyUsage]>, calendar: Calendar = .current) {
        self.file = file
        self.calendar = calendar
        days = (file.load() ?? []).sorted { $0.day < $1.day }
    }

    public func record(_ event: UsageEvent) {
        let key = dayKey(event.date)
        if let index = days.lastIndex(where: { $0.day == key }) {
            days[index].add(event)
        } else {
            var day = DailyUsage(day: key)
            day.add(event)
            days.append(day)
            days.sort { $0.day < $1.day }
        }
        if let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: event.date) {
            let cutoffKey = dayKey(cutoff)
            days.removeAll { $0.day < cutoffKey }
        }
        file.save(days)
    }

    public func removeAll() {
        days.removeAll()
        file.save(days)
    }

    /// The last `count` days up to and including `end`'s day, oldest first, with empty days filled in.
    public func series(days count: Int, endingAt end: Date = Date()) -> [(date: Date, usage: DailyUsage)] {
        let today = calendar.startOfDay(for: end)
        let byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { $1 })
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = dayKey(date)
            return (date, byDay[key] ?? DailyUsage(day: key))
        }
    }

    func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
