import AppKit
import SwiftUI

/// Colour tokens for the glass main window. The window itself is a behind-window blur; these
/// tint it towards white (light) or black (dark) and style the panels floating on top.
enum Theme {
    /// Wash over the desktop blur so the window reads as frosted white / smoked black.
    static let backdropTint = dynamic(light: NSColor(white: 1, alpha: 0.45), dark: NSColor(white: 0, alpha: 0.62))
    /// Fallback panel fill before macOS 26 (Liquid Glass supplies its own).
    static let panelFill = dynamic(light: NSColor(white: 1, alpha: 0.5), dark: NSColor(white: 1, alpha: 0.06))
    /// Specular rim on glass panels.
    static let rim = dynamic(light: NSColor(white: 1, alpha: 0.85), dark: NSColor(white: 1, alpha: 0.14))
    /// Settings cards: dense enough white that text keeps its contrast over the backdrop.
    static let cardFill = dynamic(light: NSColor(white: 1, alpha: 0.78), dark: NSColor(white: 1, alpha: 0.06))
    static let cardStroke = dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.08))
    static let separator = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.1))
    /// Fill behind the selected sidebar item and hovered rows.
    static let selection = dynamic(light: NSColor(white: 1, alpha: 0.75), dark: NSColor(white: 1, alpha: 0.14))
    static let hover = dynamic(light: NSColor(white: 1, alpha: 0.4), dark: NSColor(white: 1, alpha: 0.06))
    static let selectionShadow = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 0, alpha: 0.3))

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

    /// The logo sweep for small marks (icons, the learned-word notice). Always left to right, like
    /// the logo. See DESIGN.md.
    static let brandGradient = LinearGradient(
        colors: [brandBlue, brandLavender, brandApricot], startPoint: .leading, endPoint: .trailing)

    /// Soft colour fields taken from the logo gradient, blurred behind the glass.
    static let glowBlue = Color(red: 0.12, green: 0.45, blue: 1.0)
    static let glowMagenta = Color(red: 0.85, green: 0.25, blue: 0.95)
    static let glowOrange = Color(red: 1.0, green: 0.55, blue: 0.2)

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            })
    }
}

/// Window background: the desktop blurred through the window, a white/black wash, and faint
/// logo-coloured glows so the glass panels have something to refract.
struct GlassBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            BehindWindowBlur()
            Theme.backdropTint
            GeometryReader { proxy in
                let size = proxy.size
                let strength = colorScheme == .dark ? 0.2 : 0.22
                ZStack {
                    glow(Theme.glowBlue, diameter: size.width * 0.55)
                        .position(x: size.width * 0.12, y: size.height * 0.1)
                    glow(Theme.glowMagenta, diameter: size.width * 0.5)
                        .position(x: size.width * 0.85, y: size.height * 0.3)
                    glow(Theme.glowOrange, diameter: size.width * 0.45)
                        .position(x: size.width * 0.6, y: size.height * 1.02)
                }
                .opacity(strength)
                .blur(radius: 90)
            }
        }
        .ignoresSafeArea()
    }

    private func glow(_ color: Color, diameter: CGFloat) -> some View {
        Circle().fill(color).frame(width: diameter, height: diameter)
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
    /// A floating glass panel: Liquid Glass on macOS 26, a frosted material before that.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .background(Theme.panelFill, in: shape)
                .overlay(shape.strokeBorder(Theme.rim, lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        }
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
