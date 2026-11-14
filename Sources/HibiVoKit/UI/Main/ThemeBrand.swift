import SwiftUI

/// Colour tokens. This file holds the brand colours and needs only SwiftUI, so the iOS app and its
/// keyboard compile it too; the macOS window colours are added in Theme.swift.
enum Theme {
    /// Brand colours sampled from the logo, which sweeps left to right from cyan and blue through
    /// pink to orange and yellow. See DESIGN.md.
    static let brandCyan = Color(red: 0x00 / 255, green: 0xC0 / 255, blue: 0xFC / 255)
    static let brandBlue = Color(red: 0x00 / 255, green: 0x6A / 255, blue: 0xEC / 255)
    static let brandPink = Color(red: 0xFE / 255, green: 0x37 / 255, blue: 0x7E / 255)
    static let brandOrange = Color(red: 0xFF / 255, green: 0x77 / 255, blue: 0x00 / 255)
    static let brandYellow = Color(red: 0xFE / 255, green: 0xC2 / 255, blue: 0x00 / 255)

    /// Softened stops for the mark gradient: the logo's own pink reads as red and its orange as
    /// loud at icon size, so the middle is a pale lavender and the end a lighter orange.
    static let brandLavender = Color(red: 0xC8 / 255, green: 0xB5 / 255, blue: 0xF5 / 255)
    static let brandApricot = Color(red: 0xFF / 255, green: 0x9A / 255, blue: 0x3C / 255)

    /// Meeting bars in the usage chart, next to dictation in the accent colour. See DESIGN.md.
    static let chartMeeting = brandApricot

    /// The logo sweep for small marks (icons, the learned-word notice). Always left to right, like
    /// the logo. See DESIGN.md.
    static let brandGradient = LinearGradient(
        colors: [brandBlue, brandLavender, brandApricot], startPoint: .leading, endPoint: .trailing)

    /// Soft colour fields taken from the logo gradient, blurred behind the glass.
    static let glowBlue = Color(red: 0.12, green: 0.45, blue: 1.0)
    static let glowMagenta = Color(red: 0.85, green: 0.25, blue: 0.95)
    static let glowOrange = Color(red: 1.0, green: 0.55, blue: 0.2)
}
