/// Errors phrased for the user, never raw status codes.
public enum UserFacingError: Error, Equatable, Sendable {
    case microphoneUnavailable
    case meetingMicrophoneLost
    case missingAPIKey(provider: String)
    case invalidAPIKey(provider: String)
    case transcriptionFailed
    case transcriptionTimedOut
    case speechModelNotReady
    case network
    case nothingRecognized
    case accessibilityMissing
    case copiedOnly(reason: String)
    case cleanupFellBack
    case meetingRequiresAPIKey(provider: String)
    case meetingSaveFailed
    case meetingTranscriptionFailed
    /// The recording is kept and tried again later.
    case meetingTranscriptionDeferred
    case claudeCodeNotFound
    /// The provider chosen for minutes has no saved credentials or, for OpenAI-compatible, no model.
    case minutesProviderNotConfigured(provider: String)
    case meetingMinutesFailed

    public var message: String {
        switch self {
        case .meetingMicrophoneLost: String(localized: "マイクの録音を再開できなかったため、ミーティングを終了しました")
        case .microphoneUnavailable: String(localized: "マイクを使用できません")
        case .missingAPIKey(let provider): String(localized: "\(provider) の API Key が未設定です")
        case .invalidAPIKey(let provider): String(localized: "\(provider) の API Key が正しくありません")
        case .transcriptionFailed: String(localized: "文字起こしに失敗しました")
        case .transcriptionTimedOut: String(localized: "文字起こしがタイムアウトしました")
        case .speechModelNotReady: String(localized: "macOS の音声認識モデルを準備しています。少し待ってからもう一度お試しください")
        case .network: String(localized: "ネットワークに接続できません")
        case .nothingRecognized: String(localized: "音声を認識できませんでした")
        case .accessibilityMissing: String(localized: "アクセシビリティ権限が必要です")
        case .copiedOnly(let reason): String(localized: "\(reason)。クリップボードにコピーしました")
        case .cleanupFellBack: String(localized: "整形できなかったため、文字起こしをそのまま入力しました")
        case .meetingRequiresAPIKey(let provider): String(localized: "ミーティングの文字起こしには \(provider) の API Key が必要です")
        case .meetingSaveFailed: String(localized: "ミーティングの記録を保存できませんでした")
        case .meetingTranscriptionFailed: String(localized: "ミーティングの文字起こしに失敗しました")
        case .meetingTranscriptionDeferred: String(localized: "ミーティングの文字起こしに失敗しました。ネットワークの回復後に自動でやり直します")
        case .claudeCodeNotFound: String(localized: "Claude Code が見つからないため、議事録を作成できませんでした")
        case .minutesProviderNotConfigured(let provider): String(localized: "\(provider) の設定が済んでいないため、議事録を作成できませんでした")
        case .meetingMinutesFailed: String(localized: "議事録を作成できませんでした。文字起こしは保存済みです")
        }
    }
}
