import AppKit
import ApplicationServices

/// Accessibility is needed both for the event tap (hotkey) and for posting ⌘V.
public enum Permissions {
    public static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that points the user at System Settings.
    public static func promptForAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    public static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// "Screen & System Audio Recording", which also lists apps allowed to record system audio only.
    public static func openSystemAudioSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
