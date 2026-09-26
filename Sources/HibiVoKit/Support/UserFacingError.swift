/// Errors phrased for the user, never raw status codes.
public enum UserFacingError: Error, Equatable, Sendable {
    case microphoneUnavailable
    case missingAPIKey(provider: String)
    case invalidAPIKey(provider: String)
    case transcriptionFailed
    case transcriptionTimedOut
    case network
    case nothingRecognized
    case accessibilityMissing
    case copiedOnly(reason: String)
    case cleanupFellBack

    public var message: String {
        switch self {
        case .microphoneUnavailable: "マイクを使用できません"
        case .missingAPIKey(let provider): "\(provider) の API Key が未設定です"
        case .invalidAPIKey(let provider): "\(provider) の API Key が正しくありません"
        case .transcriptionFailed: "文字起こしに失敗しました"
        case .transcriptionTimedOut: "文字起こしがタイムアウトしました"
        case .network: "ネットワークに接続できません"
        case .nothingRecognized: "音声を認識できませんでした"
        case .accessibilityMissing: "アクセシビリティ権限が必要です"
        case .copiedOnly(let reason): "\(reason)。クリップボードにコピーしました"
        case .cleanupFellBack: "整形できなかったため、文字起こしをそのまま入力しました"
        }
    }
}
