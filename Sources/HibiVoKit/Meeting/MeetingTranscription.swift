import Foundation

/// One recognised token of a meeting, with who said it and when.
public struct MeetingToken: Equatable, Sendable {
    public var text: String
    public var isFinal: Bool
    /// Diarization label, e.g. "1". Labels are only consistent within one STT session.
    public var speaker: String?
    /// Offsets from the start of the session's audio.
    public var startMs: Int?
    public var endMs: Int?

    public init(text: String, isFinal: Bool, speaker: String? = nil, startMs: Int? = nil, endMs: Int? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.speaker = speaker
        self.startMs = startMs
        self.endMs = endMs
    }
}

public enum MeetingSessionEvent: Equatable, Sendable {
    /// The latest batch: final tokens arrive once, non-final tokens replace the previous batch's.
    case tokens([MeetingToken])
    /// The server ended the stream (nil: e.g. the session length cap) or the connection failed.
    /// Not sent when we close the session ourselves.
    case ended(TranscriptionError?)
}

/// A long-running STT session that reports tokens as they are recognised instead of one string at the end.
public protocol MeetingTranscriptionSession: TranscriptionSession {
    /// Finishes when the session closes.
    var events: AsyncStream<MeetingSessionEvent> { get }
}

/// An STT service that can transcribe a meeting, with speaker labels where it supports them.
public protocol MeetingTranscriptionProvider: TranscriptionProvider {
    /// Whether tokens carry speaker labels.
    var identifiesSpeakers: Bool { get }
    /// Whether a meeting in `language` can start now. False while an on-device model is still being
    /// downloaded: a meeting can't be retried like a dictation, so it isn't started without one.
    func isReady(language: String) -> Bool
    func makeMeetingSession(_ config: TranscriptionConfig) -> any MeetingTranscriptionSession
}

extension MeetingTranscriptionProvider {
    public var identifiesSpeakers: Bool { true }
    public func isReady(language: String) -> Bool { true }
}

/// The STT a meeting runs on, picked from the settings when it starts.
public struct MeetingTranscriber: Sendable {
    public var provider: any MeetingTranscriptionProvider
    /// Transcribes the whole recording once the meeting ends; nil when the provider only streams.
    public var fileTranscriber: (any MeetingFileTranscriber)?

    public init(provider: any MeetingTranscriptionProvider, fileTranscriber: (any MeetingFileTranscriber)? = nil) {
        self.provider = provider
        self.fileTranscriber = fileTranscriber
    }
}

/// When a meeting is transcribed.
public enum MeetingTranscriptionTiming: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Streamed while the meeting runs: live text and a file that grows as it goes.
    case realtime
    /// Recorded in memory and transcribed once it ends: much better speaker separation, nothing live.
    case afterMeeting

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .realtime: "リアルタイム"
        case .afterMeeting: "終了後にまとめて(話者の識別が高精度)"
        }
    }
}
