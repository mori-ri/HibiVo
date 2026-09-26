import Foundation

/// A user's choice of cleanup mode for one app.
public struct AppModeOverride: Codable, Hashable, Identifiable, Sendable {
    public var bundleID: String
    public var name: String
    public var mode: CleanupMode
    public var id: String { bundleID }

    public init(bundleID: String, name: String, mode: CleanupMode) {
        self.bundleID = bundleID
        self.name = name
        self.mode = mode
    }
}

/// Picks the cleanup mode for the app receiving the text: user override → built-in default → global default.
public enum AppModeRules {
    /// Sensible defaults so the app works well before anyone opens Settings.
    public static let builtIn: [String: (name: String, mode: CleanupMode)] = [
        // AI tools and terminals: dictation is usually an instruction to an AI.
        "com.apple.Terminal": ("Terminal", .prompt),
        "com.googlecode.iterm2": ("iTerm2", .prompt),
        "com.mitchellh.ghostty": ("Ghostty", .prompt),
        "dev.warp.Warp-Stable": ("Warp", .prompt),
        "com.microsoft.VSCode": ("Visual Studio Code", .prompt),
        "com.todesktop.230313mzl4w4u92": ("Cursor", .prompt),
        "com.openai.chat": ("ChatGPT", .prompt),
        "com.anthropic.claudefordesktop": ("Claude", .prompt),
        // Chat.
        "com.tinyspeck.slackmacgap": ("Slack", .natural),
        "com.microsoft.teams2": ("Microsoft Teams", .natural),
        // Mail.
        "com.microsoft.Outlook": ("Outlook", .business),
        "com.apple.mail": ("Mail", .business),
    ]

    public static func mode(for bundleID: String?, overrides: [AppModeOverride], default fallback: CleanupMode)
        -> CleanupMode
    {
        guard let bundleID else { return fallback }
        let key = bundleID.lowercased()
        if let override = overrides.first(where: { $0.bundleID.lowercased() == key }) { return override.mode }
        if let builtIn = builtIn.first(where: { $0.key.lowercased() == key }) { return builtIn.value.mode }
        return fallback
    }
}
