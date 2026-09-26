public enum CleanupMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case raw
    case natural
    case business
    case prompt

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .raw: "Raw（そのまま）"
        case .natural: "Natural（自然な文章）"
        case .business: "Business（丁寧な文章）"
        case .prompt: "Prompt（AI への指示）"
        }
    }
}
