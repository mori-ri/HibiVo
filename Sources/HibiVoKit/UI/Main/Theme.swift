import AppKit
import SwiftUI

/// Colour tokens for the main window: white in light mode, black in dark mode.
enum Theme {
    static let background = dynamic(light: .white, dark: .black)
    /// Hairline separating the sidebar from the page and the history list from its detail.
    static let separator = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.12))
    /// Fill behind the selected sidebar item and hovered rows.
    static let selection = dynamic(light: NSColor(white: 0, alpha: 0.055), dark: NSColor(white: 1, alpha: 0.1))
    static let hover = dynamic(light: NSColor(white: 0, alpha: 0.03), dark: NSColor(white: 1, alpha: 0.05))

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension View {
    /// Grouped form on the plain window background instead of the default grey.
    func pageForm() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }
}

/// Section footer for grouped forms, which otherwise trail-align it at body size.
struct FormFooter: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
    }
}

/// Colour logo from the app bundle (see scripts/make-icons.swift). Missing under `swift run`,
/// so fall back to an SF Symbol.
struct AppLogo: View {
    var height: CGFloat

    private static let image = NSImage(named: "Logo")

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
        } else {
            Image(systemName: "waveform")
                .font(.system(size: height * 0.8, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(height: height)
        }
    }
}
