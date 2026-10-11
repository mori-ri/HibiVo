import CoreGraphics

/// The key the user taps to start and stop dictation.
public enum HotkeyTrigger: Codable, Hashable, Sendable {
    case fn
    case rightOption
    case rightCommand
    /// A regular key plus modifiers, e.g. Control + Space.
    case shortcut(keyCode: UInt16, modifiers: ModifierSet)

    public static let `default`: HotkeyTrigger = .rightOption

    public static let presets: [HotkeyTrigger] = [
        .rightOption,
        .fn,
        .rightCommand,
        .shortcut(keyCode: KeyCode.space, modifiers: [.control]),
    ]

    public var displayName: String {
        switch self {
        case .fn: "Fn (🌐)"
        case .rightOption: String(localized: "右 Option")
        case .rightCommand: String(localized: "右 Command")
        case .shortcut(let keyCode, let modifiers):
            modifiers.symbols + KeyCode.displayName(keyCode)
        }
    }
}

public struct ModifierSet: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = ModifierSet(rawValue: 1 << 0)
    public static let option = ModifierSet(rawValue: 1 << 1)
    public static let shift = ModifierSet(rawValue: 1 << 2)
    public static let command = ModifierSet(rawValue: 1 << 3)

    init(_ flags: CGEventFlags) {
        var set: ModifierSet = []
        if flags.contains(.maskControl) { set.insert(.control) }
        if flags.contains(.maskAlternate) { set.insert(.option) }
        if flags.contains(.maskShift) { set.insert(.shift) }
        if flags.contains(.maskCommand) { set.insert(.command) }
        self = set
    }

    var symbols: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

public enum KeyCode {
    public static let space: UInt16 = 49
    public static let escape: UInt16 = 53
    public static let rightCommand: UInt16 = 54
    public static let rightOption: UInt16 = 61
    public static let fn: UInt16 = 63
    public static let v: UInt16 = 9
    public static let m: UInt16 = 46

    static func displayName(_ keyCode: UInt16) -> String {
        switch keyCode {
        case space: "Space"
        case escape: "Esc"
        default: "Key\(keyCode)"
        }
    }
}
