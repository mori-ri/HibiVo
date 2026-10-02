/// Errors phrased for the user, never raw status codes.
public enum UserFacingError: Error, Equatable, Sendable {
    case microphoneUnavailable
    case missingAPIKey(provider: String)
    case invalidAPIKey(provider: String)
    case missingEndpoint(provider: String)
    case transcriptionFailed
    case transcriptionTimedOut
    case network
    case nothingRecognized
    case accessibilityMissing
    case copiedOnly(reason: String)
    case cleanupFellBack
    case meetingRequiresAPIKey(provider: String)
    case meetingSaveFailed
    case meetingTranscriptionFailed
    case claudeCodeNotFound
    case meetingMinutesFailed

    public var message: String {
        switch self {
        case .microphoneUnavailable: "マイクを使用できません"
        case .missingAPIKey(let provider): "\(provider) の API Key が未設定です"
        case .invalidAPIKey(let provider): "\(provider) の API Key が正しくありません"
        case .missingEndpoint(let provider): "\(provider) のエンドポイントが未設定です"
        case .transcriptionFailed: "文字起こしに失敗しました"
        case .transcriptionTimedOut: "文字起こしがタイムアウトしました"
        case .network: "ネットワークに接続できません"
        case .nothingRecognized: "音声を認識できませんでした"
        case .accessibilityMissing: "アクセシビリティ権限が必要です"
        case .copiedOnly(let reason): "\(reason)。クリップボードにコピーしました"
        case .cleanupFellBack: "整形できなかったため、文字起こしをそのまま入力しました"
        case .meetingRequiresAPIKey(let provider): "ミーティングの文字起こしには \(provider) の API Key が必要です"
        case .meetingSaveFailed: "ミーティングの記録を保存できませんでした"
        case .meetingTranscriptionFailed: "ミーティングの文字起こしに失敗しました"
        case .claudeCodeNotFound: "Claude Code が見つからないため、議事録を作成できませんでした"
        case .meetingMinutesFailed: "議事録を作成できませんでした。文字起こしは保存済みです"
        }
    }
}
