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
    case bedrockMinutesCredentialsMissing
    case meetingMinutesFailed

    public var message: String {
        switch self {
        case .meetingMicrophoneLost: "マイクの録音を再開できなかったため、ミーティングを終了しました"
        case .microphoneUnavailable: "マイクを使用できません"
        case .missingAPIKey(let provider): "\(provider) の API Key が未設定です"
        case .invalidAPIKey(let provider): "\(provider) の API Key が正しくありません"
        case .transcriptionFailed: "文字起こしに失敗しました"
        case .transcriptionTimedOut: "文字起こしがタイムアウトしました"
        case .speechModelNotReady: "macOS の音声認識モデルを準備しています。少し待ってからもう一度お試しください"
        case .network: "ネットワークに接続できません"
        case .nothingRecognized: "音声を認識できませんでした"
        case .accessibilityMissing: "アクセシビリティ権限が必要です"
        case .copiedOnly(let reason): "\(reason)。クリップボードにコピーしました"
        case .cleanupFellBack: "整形できなかったため、文字起こしをそのまま入力しました"
        case .meetingRequiresAPIKey(let provider): "ミーティングの文字起こしには \(provider) の API Key が必要です"
        case .meetingSaveFailed: "ミーティングの記録を保存できませんでした"
        case .meetingTranscriptionFailed: "ミーティングの文字起こしに失敗しました"
        case .meetingTranscriptionDeferred: "ミーティングの文字起こしに失敗しました。ネットワークの回復後に自動でやり直します"
        case .claudeCodeNotFound: "Claude Code が見つからないため、議事録を作成できませんでした"
        case .bedrockMinutesCredentialsMissing: "Amazon Bedrock の認証情報が未設定のため、議事録を作成できませんでした"
        case .meetingMinutesFailed: "議事録を作成できませんでした。文字起こしは保存済みです"
        }
    }
}
