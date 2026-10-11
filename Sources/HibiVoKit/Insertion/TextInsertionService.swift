import AppKit
import Carbon.HIToolbox
import OSLog

public enum InsertionOutcome: Equatable, Sendable {
    case pasted
    /// Could not paste; the text was left on the clipboard for the user to paste manually.
    case copiedOnly(reason: String)
}

@MainActor
public protocol TextInserting {
    func insert(_ text: String, into target: TargetApplication?) async -> InsertionOutcome
}

/// Pastes text into the target app via the clipboard and ⌘V, then restores the old clipboard.
///
/// Clipboard + ⌘V is used instead of Accessibility value setting because it works the same in
/// native apps, browsers, Electron apps (Slack, VS Code, Cursor) and terminals.
@MainActor
public final class TextInsertionService: TextInserting {
    /// Time for the target app to read the pasteboard before we put the old contents back.
    /// Electron apps occasionally need more than 100–200 ms.
    static let restoreDelay: Duration = .milliseconds(350)
    static let activationDelay: Duration = .milliseconds(150)

    private let clipboard: ClipboardManager
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "insertion")

    public init() {
        clipboard = ClipboardManager()
    }

    init(clipboard: ClipboardManager) {
        self.clipboard = clipboard
    }

    public func insert(_ text: String, into target: TargetApplication?) async -> InsertionOutcome {
        guard AXIsProcessTrusted() else {
            return copyOnly(text, reason: String(localized: "アクセシビリティ権限がありません"))
        }
        // Password fields enable Secure Input, which drops synthetic key events.
        guard !IsSecureEventInputEnabled() else {
            return copyOnly(text, reason: String(localized: "パスワード入力中のため貼り付けできません"))
        }
        if let target {
            guard let app = NSRunningApplication(processIdentifier: target.processID), !app.isTerminated else {
                return copyOnly(text, reason: String(localized: "\(target.name) が終了しています"))
            }
            if !app.isActive {
                app.activate()
                try? await Task.sleep(for: Self.activationDelay)
            }
        }

        let snapshot = clipboard.snapshot()
        let changeCount = clipboard.write(text, transient: true)
        Self.postCommandV()
        try? await Task.sleep(for: Self.restoreDelay)
        if !clipboard.restore(snapshot, ifChangeCountIs: changeCount) {
            log.notice("Clipboard changed during paste; leaving the new contents alone")
        }
        return .pasted
    }

    private func copyOnly(_ text: String, reason: String) -> InsertionOutcome {
        _ = clipboard.write(text, transient: false)
        return .copiedOnly(reason: reason)
    }

    static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(KeyCode.v), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(KeyCode.v), keyDown: false)
        // Explicit flags so a still-held modifier (e.g. the Option trigger) can't turn this into ⌥⌘V.
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
