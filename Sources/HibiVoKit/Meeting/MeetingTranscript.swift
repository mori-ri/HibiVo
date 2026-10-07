import Foundation

/// Folds meeting tokens into speaker-labelled paragraphs. Pure so it can be unit tested.
///
/// Times are kept relative to the start of the meeting: each STT session reports offsets from its
/// own start, so tokens are shifted by `offsetMs` (the meeting time at which the session opened).
public struct MeetingTranscript: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case speech(speaker: String?)
            /// The STT connection was re-established; speaker labels restart from here.
            case reconnected
        }

        public var kind: Kind
        /// Which STT session produced it; speaker labels are only comparable within one session.
        public var session: Int
        public var startMs: Int
        public var endMs: Int
        public var text: String
    }

    /// A pause at least this long starts a new paragraph even when the speaker stays the same.
    static let paragraphGapMs = 4_000
    /// How much text the HUD shows.
    static let liveTailLength = 60

    public private(set) var segments: [Segment] = []
    public private(set) var tentativeText = ""
    /// Meeting time at which the current STT session started.
    public var offsetMs = 0
    /// Counts STT sessions; bumped by `markReconnect`.
    public private(set) var session = 0

    public init() {}

    public var isEmpty: Bool {
        !segments.contains { if case .speech = $0.kind { !$0.text.isEmpty } else { false } }
    }

    /// The end of the running transcript, final and tentative, for live display.
    public var liveTail: String {
        let last = segments.last { if case .speech = $0.kind { true } else { false } }?.text ?? ""
        let text = (last + tentativeText).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.suffix(Self.liveTailLength))
    }

    public mutating func apply(_ tokens: [MeetingToken]) {
        var tentative = ""
        for token in tokens {
            guard token.isFinal else {
                tentative += token.text
                continue
            }
            append(token)
        }
        tentativeText = tentative
    }

    /// Marks where a new STT session took over, from `atMs` meeting time on.
    public mutating func markReconnect(atMs: Int) {
        tentativeText = ""
        offsetMs = atMs
        session += 1
        segments.append(Segment(kind: .reconnected, session: session, startMs: atMs, endMs: atMs, text: ""))
    }

    private mutating func append(_ token: MeetingToken) {
        let previousEnd = segments.last?.endMs ?? offsetMs
        let start = token.startMs.map { $0 + offsetMs } ?? previousEnd
        let end = token.endMs.map { $0 + offsetMs } ?? start
        let kind = Segment.Kind.speech(speaker: token.speaker)

        if var last = segments.last, last.kind == kind, last.session == session,
            start - last.endMs < Self.paragraphGapMs
        {
            last.text += token.text
            last.endMs = max(last.endMs, end)
            segments[segments.count - 1] = last
        } else {
            // English tokens carry their own leading space; drop it at the start of a paragraph.
            let text = token.text.drop { $0 == " " }
            guard !text.isEmpty else { return }
            segments.append(Segment(kind: kind, session: session, startMs: start, endMs: end, text: String(text)))
        }
    }
}

/// Renders a meeting transcript as the Markdown file saved on disk.
public enum MeetingDocument {
    /// Something worth telling the reader about how the audio was captured.
    public enum Notice: String, Codable, Equatable, Sendable {
        case microphoneUnavailable
        case systemAudioUnavailable
        case systemAudioSilent
    }

    /// Heading of the user's notes in the transcript. The minutes prompt refers to it by this name.
    static let notesHeading = "## メモ"

    /// - Parameters:
    ///   - includesSystemAudio: Whether the Mac's audio output was mixed in with the microphone.
    ///   - identifiesSpeakers: Whether the STT labelled speakers; macOS's recognizer doesn't.
    ///   - notes: What the user wrote during the meeting, placed before the transcript so the minutes
    ///     are written with it.
    public static func markdown(
        _ transcript: MeetingTranscript, startedAt: Date, endedAt: Date?, includesSystemAudio: Bool = false,
        identifiesSpeakers: Bool = true, notices: [Notice] = [], notes: String = "",
        vocabulary: [VocabularyEntry] = [], timeZone: TimeZone = .current
    ) -> String {
        var lines = ["# ミーティング \(format(startedAt, "yyyy-MM-dd HH:mm", timeZone))", ""]
        lines.append("- 開始: \(format(startedAt, "yyyy-MM-dd HH:mm:ss", timeZone))")
        if let endedAt {
            let minutes = max(0, Int(endedAt.timeIntervalSince(startedAt) / 60))
            lines.append("- 終了: \(format(endedAt, "yyyy-MM-dd HH:mm:ss", timeZone))(\(minutes) 分)")
        } else {
            lines.append("- 記録中")
        }
        lines.append(includesSystemAudio ? "- 音声: マイクとシステム音声(相手の声)" : "- 音声: マイクのみ")
        lines.append(
            identifiesSpeakers
                ? "- 話者は音声から自動で推定しています。番号は実際の人物と一致しないことがあります。"
                : "- macOS 標準の文字起こしで記録したため、話者は区別していません。")
        for notice in notices {
            switch notice {
            case .microphoneUnavailable:
                lines.append("- マイクの切り替え後に録音を再開できなかったため、ミーティングの記録を終了しました。")
            case .systemAudioUnavailable:
                lines.append("- システム音声を取得できなかったため、オンライン参加者の声は記録されていません。")
            case .systemAudioSilent:
                lines.append(
                    "- システム音声が最後まで無音でした。相手の声が入っていない場合は、システム設定 › プライバシーとセキュリティ で HibiVo にシステムオーディオの録音を許可してください。"
                )
            }
        }
        if let section = notesSection(notes) { lines += ["", section] }
        lines += ["", "---", ""]

        let labels = speakerLabels(transcript)
        for segment in transcript.segments {
            let time = "[\(timestamp(segment.startMs))]"
            switch segment.kind {
            case .reconnected:
                lines.append(
                    identifiesSpeakers
                        ? "*\(time) 文字起こしが途切れたため再接続しました。以降は同じ人でも別の番号になることがあります。*"
                        : "*\(time) 文字起こしが途切れたため再開しました。*")
            case .speech(let speaker):
                let text = VocabularyReplacer.apply(vocabulary, to: segment.text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let label = labels[SpeakerKey(session: segment.session, speaker: speaker)].map { " **\($0)**" } ?? ""
                lines.append("\(time)\(label) \(text)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// The notes under their heading; nil when nothing was written.
    static func notesSection(_ notes: String) -> String? {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "\(notesHeading)\n\n\(trimmed)"
    }

    /// The minutes file: Claude's title and minutes, and where they came from. The user's notes are
    /// not copied here; Claude takes what matters from them in the transcript.
    static func minutes(title: String?, body: String, transcriptFileName: String) -> String {
        ["# \(title ?? "議事録")", body, "---", "*Claude が文字起こし「\(transcriptFileName)」から作成しました。*\n"]
            .joined(separator: "\n\n")
    }

    struct SpeakerKey: Hashable {
        var session: Int
        var speaker: String?
    }

    /// Numbers speakers in order of first appearance. A new STT session relabels everyone, so its
    /// speakers get fresh numbers rather than colliding with earlier ones.
    static func speakerLabels(_ transcript: MeetingTranscript) -> [SpeakerKey: String] {
        var order: [SpeakerKey] = []
        for segment in transcript.segments {
            guard case .speech(let speaker) = segment.kind, speaker != nil else { continue }
            let key = SpeakerKey(session: segment.session, speaker: speaker)
            if !order.contains(key) { order.append(key) }
        }
        return Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, "話者\($0.offset + 1)") })
    }

    /// `HH:mm:ss` from the start of the meeting.
    static func timestamp(_ ms: Int) -> String {
        let seconds = max(0, ms / 1000)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    /// File name for a meeting that started at `date`, e.g. `2026-09-27_14-00-05.md`.
    public static func fileName(startedAt date: Date, timeZone: TimeZone = .current) -> String {
        format(date, "yyyy-MM-dd_HH-mm-ss", timeZone) + ".md"
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
