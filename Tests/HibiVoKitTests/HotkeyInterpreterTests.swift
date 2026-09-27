import CoreGraphics
import Testing

@testable import HibiVoKit

@Suite struct HotkeyInterpreterTests {
    // Generic + device-dependent bits as macOS reports them.
    let rightOptionDown: UInt64 = CGEventFlags.maskAlternate.rawValue | 0x40
    let leftOptionDown: UInt64 = CGEventFlags.maskAlternate.rawValue | 0x20
    let fnDown: UInt64 = CGEventFlags.maskSecondaryFn.rawValue

    @Test func rightOptionPressAndRelease() {
        var sut = HotkeyInterpreter(trigger: .rightOption)
        let down = sut.handle(KeyEvent(kind: .flagsChanged, keyCode: KeyCode.rightOption, flags: rightOptionDown))
        #expect(down == .init(action: .pressed, consume: false))
        #expect(sut.isHeld)
        let up = sut.handle(KeyEvent(kind: .flagsChanged, keyCode: KeyCode.rightOption, flags: 0))
        #expect(up == .init(action: .released, consume: false))
        #expect(!sut.isHeld)
    }

    @Test func rightOptionReleaseDetectedWhileLeftOptionHeld() {
        var sut = HotkeyInterpreter(trigger: .rightOption)
        _ = sut.handle(KeyEvent(kind: .flagsChanged, keyCode: KeyCode.rightOption, flags: rightOptionDown | 0x20))
        // Generic ⌥ flag is still set because Left Option is down; device bit tells us Right is up.
        let up = sut.handle(KeyEvent(kind: .flagsChanged, keyCode: KeyCode.rightOption, flags: leftOptionDown))
        #expect(up.action == .released)
    }

    @Test func leftOptionDoesNotTrigger() {
        var sut = HotkeyInterpreter(trigger: .rightOption)
        let out = sut.handle(KeyEvent(kind: .flagsChanged, keyCode: 58, flags: leftOptionDown))
        #expect(out.action == nil)
    }

    @Test func otherKeyWhileHoldingInterrupts() {
        var sut = HotkeyInterpreter(trigger: .rightOption)
        _ = sut.handle(KeyEvent(kind: .flagsChanged, keyCode: KeyCode.rightOption, flags: rightOptionDown))
        let out = sut.handle(KeyEvent(kind: .keyDown, keyCode: 0, flags: rightOptionDown))
        #expect(out == .init(action: .interrupted, consume: false))
        // The release that follows must not produce a second action.
        let up = sut.handle(KeyEvent(kind: .flagsChanged, keyCode: KeyCode.rightOption, flags: 0))
        #expect(up.action == nil)
    }

    @Test func fnPressAndRelease() {
        var sut = HotkeyInterpreter(trigger: .fn)
        #expect(sut.handle(KeyEvent(kind: .flagsChanged, keyCode: KeyCode.fn, flags: fnDown)).action == .pressed)
        #expect(sut.handle(KeyEvent(kind: .flagsChanged, keyCode: KeyCode.fn, flags: 0)).action == .released)
    }

    @Test func duplicateFlagsChangedIsIgnored() {
        var sut = HotkeyInterpreter(trigger: .fn)
        _ = sut.handle(KeyEvent(kind: .flagsChanged, keyCode: KeyCode.fn, flags: fnDown))
        #expect(sut.handle(KeyEvent(kind: .flagsChanged, keyCode: KeyCode.fn, flags: fnDown)).action == nil)
    }

    @Test func escapeCancelsOnlyWhileRecording() {
        var sut = HotkeyInterpreter(trigger: .rightOption)
        #expect(sut.handle(KeyEvent(kind: .keyDown, keyCode: KeyCode.escape, flags: 0)).action == nil)
        sut.isRecording = true
        #expect(
            sut.handle(KeyEvent(kind: .keyDown, keyCode: KeyCode.escape, flags: 0))
                == .init(action: .escape, consume: true))
    }

    @Test func shortcutPressRepeatRelease() {
        let control = CGEventFlags.maskControl.rawValue
        var sut = HotkeyInterpreter(trigger: .shortcut(keyCode: KeyCode.space, modifiers: [.control]))
        #expect(
            sut.handle(KeyEvent(kind: .keyDown, keyCode: KeyCode.space, flags: control))
                == .init(action: .pressed, consume: true))
        // Auto-repeat is swallowed without a new action.
        #expect(
            sut.handle(KeyEvent(kind: .keyDown, keyCode: KeyCode.space, flags: control, isRepeat: true))
                == .init(action: nil, consume: true))
        #expect(
            sut.handle(KeyEvent(kind: .keyUp, keyCode: KeyCode.space, flags: control))
                == .init(action: .released, consume: true))
    }

    @Test func shortcutRequiresExactModifiers() {
        let flags = CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
        var sut = HotkeyInterpreter(trigger: .shortcut(keyCode: KeyCode.space, modifiers: [.control]))
        #expect(sut.handle(KeyEvent(kind: .keyDown, keyCode: KeyCode.space, flags: flags)).action == nil)
        #expect(sut.handle(KeyEvent(kind: .keyDown, keyCode: KeyCode.space, flags: 0)).action == nil)
    }

    @Test func shortcutEndsWhenModifierReleasedFirst() {
        let control = CGEventFlags.maskControl.rawValue
        var sut = HotkeyInterpreter(trigger: .shortcut(keyCode: KeyCode.space, modifiers: [.control]))
        _ = sut.handle(KeyEvent(kind: .keyDown, keyCode: KeyCode.space, flags: control))
        #expect(sut.handle(KeyEvent(kind: .flagsChanged, keyCode: 59, flags: 0)).action == .released)
    }
}
