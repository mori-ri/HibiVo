// Errors phrased for the user, never raw status codes. Wording matches the macOS app's UserFacingError.

export type UserFacingError =
  | { kind: "microphoneUnavailable" }
  | { kind: "missingAPIKey"; provider: string }
  | { kind: "invalidAPIKey"; provider: string }
  | { kind: "transcriptionFailed" }
  | { kind: "transcriptionTimedOut" }
  | { kind: "network" }
  | { kind: "nothingRecognized" }
  | { kind: "copiedOnly"; reason: string }
  | { kind: "cleanupFellBack" };

export function userFacingMessage(error: UserFacingError): string {
  switch (error.kind) {
    case "microphoneUnavailable":
      return "マイクを使用できません";
    case "missingAPIKey":
      return `${error.provider} の API Key が未設定です`;
    case "invalidAPIKey":
      return `${error.provider} の API Key が正しくありません`;
    case "transcriptionFailed":
      return "文字起こしに失敗しました";
    case "transcriptionTimedOut":
      return "文字起こしがタイムアウトしました";
    case "network":
      return "ネットワークに接続できません";
    case "nothingRecognized":
      return "音声を認識できませんでした";
    case "copiedOnly":
      return `${error.reason}。クリップボードにコピーしました`;
    case "cleanupFellBack":
      return "整形できなかったため、文字起こしをそのまま入力しました";
  }
}
