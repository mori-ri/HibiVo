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
    public var onAction: ((HotkeyAction) -> Void)?

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

    fileprivate func handle(type: CGEventType, event keyEvent: KeyEvent?) -> Bool {
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
            if let action = output.action { onAction?(action) }
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
        default: nil
        }
    let monitorAddress = UInt(bitPattern: userInfo)
    let consume = MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: monitorAddress) else { return false }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(pointer).takeUnretainedValue()
        return monitor.handle(type: type, event: keyEvent)
    }
    return consume ? nil : Unmanaged.passUnretained(event)
}
