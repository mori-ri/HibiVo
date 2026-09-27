import Foundation

/// What the user sees in the HUD and menu bar icon.
public enum DictationPhase: Equatable, Sendable {
    case idle
    case recording
    case processing
    /// Meeting transcription: recording until the trigger is pressed again.
    case meeting
    case error(String)

    public var isActive: Bool {
        switch self {
        case .recording, .processing, .meeting: true
        case .idle, .error: false
        }
    }
}

/// Observable UI state shared by the HUD, menu bar and settings.
@MainActor
@Observable
public final class AppState {
    public var phase: DictationPhase = .idle
    /// Smoothed microphone level (0...1) while recording.
    public var audioLevel: Float = 0
    /// Live partial transcript from streaming STT, if the provider supplies one.
    public var partialTranscript = ""
    /// When the running meeting started; nil outside meeting mode.
    public var meetingStartedAt: Date?
    /// The meeting's STT connection dropped and is being re-established.
    public var meetingReconnecting = false
    public var hasAccessibilityPermission = false
    public var hasMicrophonePermission = false
    /// Page shown in the main window; the menu bar sets it before opening the window.
    public var mainSection: MainSection = .history

    public init() {}
}
