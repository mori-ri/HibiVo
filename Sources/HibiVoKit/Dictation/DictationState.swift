import Foundation

/// What the user sees in the HUD and menu bar icon.
public enum DictationPhase: Equatable, Sendable {
    case idle
    case recording
    case processing
    case error(String)

    public var isActive: Bool {
        switch self {
        case .recording, .processing: true
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
    public var hasAccessibilityPermission = false
    public var hasMicrophonePermission = false

    public init() {}
}
