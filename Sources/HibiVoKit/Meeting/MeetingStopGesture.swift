/// Recognises the double tap of the trigger that ends a meeting. Pure so it can be unit tested.
///
/// A single press is too easy to make by accident: Fn is also held for volume, brightness and
/// arrow-key shortcuts, and macOS reports some of those (the media keys) as a plain Fn press and
/// release. A meeting can't be recorded again, so it takes two short taps in quick succession;
/// anything else in between — a long hold, another key, Esc — starts the count over.
public struct MeetingStopGesture: Sendable {
    /// Longer than this is a hold (e.g. Fn held for a shortcut), not a tap.
    public static let maximumTap: Duration = .milliseconds(400)
    /// The second tap has to start this soon after the first one ended.
    public static let maximumGap: Duration = .milliseconds(500)

    private var pressedAt: ContinuousClock.Instant?
    private var lastTapEndedAt: ContinuousClock.Instant?
    /// Whether the current press began soon enough after a tap to be its second half.
    private var isSecondPress = false

    public init() {}

    /// True when the action completes a double tap.
    public mutating func handle(_ action: HotkeyAction, at time: ContinuousClock.Instant) -> Bool {
        switch action {
        case .meeting:
            // Trigger+M, the same keys that started the meeting.
            reset()
            return true
        case .pressed:
            isSecondPress = lastTapEndedAt.map { time - $0 <= Self.maximumGap } ?? false
            pressedAt = time
            lastTapEndedAt = nil
            return false
        case .released:
            guard let pressedAt, time - pressedAt <= Self.maximumTap else {
                reset()
                return false
            }
            if isSecondPress {
                reset()
                return true
            }
            self.pressedAt = nil
            lastTapEndedAt = time
            return false
        case .interrupted, .escape:
            reset()
            return false
        }
    }

    public mutating func reset() {
        pressedAt = nil
        lastTapEndedAt = nil
        isSecondPress = false
    }
}
