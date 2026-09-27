import CoreGraphics

/// What a raw keyboard event means for the dictation hotkey.
public enum HotkeyAction: Equatable, Sendable {
    case pressed
    case released
    /// Another key was pressed while the trigger was held (e.g. ⌥+letter). Recording should be cancelled.
    case interrupted
    case escape
    /// M was pressed while the trigger was held: start (or stop) meeting transcription.
    case meeting
}

/// A keyboard event reduced to the fields the interpreter needs. Pure so it can be unit tested.
public struct KeyEvent: Sendable {
    public enum Kind: Sendable { case keyDown, keyUp, flagsChanged }
    public var kind: Kind
    public var keyCode: UInt16
    public var flags: UInt64
    public var isRepeat: Bool

    public init(kind: Kind, keyCode: UInt16, flags: UInt64, isRepeat: Bool = false) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
        self.isRepeat = isRepeat
    }
}

/// Turns key events into hotkey actions, tracking whether the trigger is held.
///
/// Modifier triggers use device-dependent flag bits so that e.g. holding Left Option
/// does not mask the release of Right Option.
public struct HotkeyInterpreter: Sendable {
    public struct Output: Equatable, Sendable {
        public var action: HotkeyAction?
        /// Whether the event should be swallowed so the frontmost app never sees it.
        public var consume: Bool
    }

    // NX_DEVICE*KEYMASK values from IOKit/hidsystem/IOLLEvent.h
    static let deviceRightOption: UInt64 = 0x40
    static let deviceRightCommand: UInt64 = 0x10

    public var trigger: HotkeyTrigger
    public private(set) var isHeld = false
    /// Set while a recording is active so Esc can be swallowed only then.
    public var isRecording = false
    /// The M that toggled a meeting is swallowed on the way down, so swallow its key-up too.
    private var swallowMeetingKeyUp = false

    public init(trigger: HotkeyTrigger) {
        self.trigger = trigger
    }

    public mutating func handle(_ event: KeyEvent) -> Output {
        if event.kind == .keyDown, event.keyCode == KeyCode.escape, isRecording {
            isHeld = false
            return Output(action: .escape, consume: true)
        }
        if event.kind == .keyUp, event.keyCode == KeyCode.m, swallowMeetingKeyUp {
            swallowMeetingKeyUp = false
            return Output(action: nil, consume: true)
        }

        switch trigger {
        case .fn:
            return handleModifier(event, keyCode: KeyCode.fn) {
                $0 & CGEventFlags.maskSecondaryFn.rawValue != 0
            }
        case .rightOption:
            return handleModifier(event, keyCode: KeyCode.rightOption) {
                $0 & Self.deviceRightOption != 0
            }
        case .rightCommand:
            return handleModifier(event, keyCode: KeyCode.rightCommand) {
                $0 & Self.deviceRightCommand != 0
            }
        case .shortcut(let keyCode, let modifiers):
            return handleShortcut(event, keyCode: keyCode, modifiers: modifiers)
        }
    }

    private mutating func handleModifier(
        _ event: KeyEvent, keyCode: UInt16, isDown: (UInt64) -> Bool
    ) -> Output {
        switch event.kind {
        case .flagsChanged where event.keyCode == keyCode:
            let down = isDown(event.flags)
            guard down != isHeld else { return Output(action: nil, consume: false) }
            isHeld = down
            // Modifier events are never swallowed: doing so desynchronises the system's modifier state.
            return Output(action: down ? .pressed : .released, consume: false)
        case .keyDown where isHeld && !event.isRepeat && event.keyCode == KeyCode.m:
            return meetingToggle()
        case .keyDown where isHeld && !event.isRepeat:
            isHeld = false
            return Output(action: .interrupted, consume: false)
        default:
            return Output(action: nil, consume: false)
        }
    }

    private mutating func handleShortcut(
        _ event: KeyEvent, keyCode: UInt16, modifiers: ModifierSet
    ) -> Output {
        let current = ModifierSet(CGEventFlags(rawValue: event.flags))
        switch event.kind {
        case .keyDown where event.keyCode == keyCode:
            if isHeld { return Output(action: nil, consume: true) }  // key repeat
            guard current == modifiers else { return Output(action: nil, consume: false) }
            isHeld = true
            return Output(action: .pressed, consume: true)
        case .keyUp where event.keyCode == keyCode && isHeld:
            isHeld = false
            return Output(action: .released, consume: true)
        case .flagsChanged where isHeld && !current.isSuperset(of: modifiers):
            // Letting go of a modifier before the key also ends the recording.
            isHeld = false
            return Output(action: .released, consume: false)
        case .keyDown where isHeld && event.keyCode == KeyCode.m:
            return meetingToggle()
        case .keyDown where isHeld:
            isHeld = false
            return Output(action: .interrupted, consume: false)
        default:
            return Output(action: nil, consume: false)
        }
    }

    /// Ends the hold without a release, so letting go of the trigger afterwards is not an action.
    private mutating func meetingToggle() -> Output {
        isHeld = false
        swallowMeetingKeyUp = true
        return Output(action: .meeting, consume: true)
    }

    public mutating func reset() {
        isHeld = false
        isRecording = false
        swallowMeetingKeyUp = false
    }
}
