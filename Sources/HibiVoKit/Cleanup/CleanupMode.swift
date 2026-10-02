public enum CleanupMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case raw
    case natural
    case business
    case prompt
    /// Follows instructions the user wrote in settings (`SettingsStore.customCleanupInstructions`).
    case custom

    /// Most characters the custom instructions may have. Keeps the system prompt, sent with every utterance, small.
    public static let customInstructionsLimit = 1000

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .raw: "Raw（そのまま）"
        case .natural: "Natural（自然な文章）"
        case .business: "Business（丁寧な文章）"
        case .prompt: "Prompt（AI への指示）"
        case .custom: "Custom（カスタム指示）"
        }
    }
}
