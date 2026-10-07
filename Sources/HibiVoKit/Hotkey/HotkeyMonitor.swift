import AppKit
import CoreGraphics
import Foundation
import OSLog

/// Listens for the global dictation hotkey via a CGEventTap.
///
/// An active (non listen-only) tap is used so the shortcut keystroke itself can be swallowed.
/// It requires the Accessibility permission. The tap is installed on the main run loop, so the
/// callback always runs on the main thread.
@MainActor
public final class HotkeyMonitor {
    /// Called with the action and when the key event actually happened, which can be well before the
    /// callback runs if the main thread was busy (e.g. starting the audio engine).
    public var onAction: ((HotkeyAction, ContinuousClock.Instant) -> Void)?

    private var interpreter: HotkeyInterpreter
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "hotkey")

    public init(trigger: HotkeyTrigger) {
        interpreter = HotkeyInterpreter(trigger: trigger)
    }

    public var isRunning: Bool { tap != nil }

    public var trigger: HotkeyTrigger {
        get { interpreter.trigger }
        set {
            interpreter.trigger = newValue
            interpreter.reset()
        }
    }

    /// Lets the interpreter know whether Esc should be captured.
    public var isRecording: Bool {
        get { interpreter.isRecording }
        set { interpreter.isRecording = newValue }
    }

    /// Returns false when the tap could not be created (usually missing Accessibility permission).
    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << systemDefinedEventType)

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: hotkeyTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            log.error("CGEvent.tapCreate failed; Accessibility permission is probably missing")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return true
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        interpreter.reset()
    }

    fileprivate func handle(type: CGEventType, event keyEvent: KeyEvent?, occurredAt: ContinuousClock.Instant) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disables taps that respond slowly. Re-enable and keep the held state: if the
            // release was missed, the next press/release pair recovers, and recordings are time-capped.
            log.notice("Event tap was disabled (\(type.rawValue)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        default:
            guard let keyEvent else { return false }
            let output = interpreter.handle(keyEvent)
            if let action = output.action { onAction?(action, occurredAt) }
            return output.consume
        }
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    // Copy the fields out here so nothing non-Sendable crosses into the main actor closure.
    let keyEvent: KeyEvent? =
        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            KeyEvent(
                kind: type == .keyDown ? .keyDown : type == .keyUp ? .keyUp : .flagsChanged,
                keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                flags: event.flags.rawValue,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case _ where type.rawValue == systemDefinedEventType: mediaKeyDown(event)
        default: nil
        }
    let occurredAt = keyEvent == nil ? ContinuousClock.now : eventTime(event)
    let monitorAddress = UInt(bitPattern: userInfo)
    let consume = MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: monitorAddress) else { return false }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(pointer).takeUnretainedValue()
        return monitor.handle(type: type, event: keyEvent, occurredAt: occurredAt)
    }
    return consume ? nil : Unmanaged.passUnretained(event)
}

/// NX_SYSDEFINED: media keys arrive as this event type, which CGEventType has no case for.
private let systemDefinedEventType: UInt32 = 14

/// A media key press (volume, brightness …), so that holding Fn for one counts as using another key.
/// Only key-downs of NX_SUBTYPE_AUX_CONTROL_BUTTONS; the other system-defined events (aux mouse
/// buttons, power key …) are not keys the user combines with the trigger.
private func mediaKeyDown(_ event: CGEvent) -> KeyEvent? {
    guard let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8
    else { return nil }
    let data = nsEvent.data1
    // data1: NX_KEYTYPE in the high 16 bits, key state in bits 8-15 (0xA down, 0xB up).
    guard (data & 0xFF00) >> 8 == 0xA, data & 0x1 == 0 else { return nil }
    return KeyEvent(kind: .mediaKeyDown, keyCode: UInt16(truncatingIfNeeded: (data & 0xFFFF_0000) >> 16), flags: 0)
}

/// When the key event happened, on the clock the dictation controller measures holds with.
///
/// Events queue up while the main thread is busy, so the callback's own time can be far too late:
/// a short tap whose release waited behind a slow audio engine start looked like a long hold.
/// NSEvent's timestamp shares its time base with `systemUptime`, which avoids CGEventTimestamp's
/// unit differences across architectures.
private func eventTime(_ event: CGEvent) -> ContinuousClock.Instant {
    let now = ContinuousClock.now
    guard let timestamp = NSEvent(cgEvent: event)?.timestamp, timestamp > 0 else { return now }
    let age = ProcessInfo.processInfo.systemUptime - timestamp
    // Anything outside this range means the timestamp is unusable; fall back to the callback time.
    guard age > 0, age < 10 else { return now }
    return now - .seconds(age)
}
