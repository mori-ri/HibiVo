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

/// Picks the cleanup mode for the app receiving the text: user setting → global default.
public enum AppModeRules {
    /// Seeded into the user's settings on first launch, then editable and removable like any other entry.
    /// Only apps that ship with macOS, so the list never shows apps the user doesn't have.
    public static let initialOverrides: [AppModeOverride] = [
        AppModeOverride(bundleID: "com.apple.Terminal", name: "Terminal", mode: .prompt),
        AppModeOverride(bundleID: "com.apple.mail", name: "Mail", mode: .business),
    ]

    public static func mode(for bundleID: String?, overrides: [AppModeOverride], default fallback: CleanupMode)
        -> CleanupMode
    {
        guard let bundleID else { return fallback }
        let key = bundleID.lowercased()
        return overrides.first(where: { $0.bundleID.lowercased() == key })?.mode ?? fallback
    }
}
