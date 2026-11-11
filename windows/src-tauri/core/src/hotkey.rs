//! Turns raw keyboard events into dictation hotkey actions. A port of the macOS app's `HotkeyInterpreter`,
//! working on Windows virtual-key codes as the low-level keyboard hook sees them.

/// Virtual-key codes the interpreter cares about.
pub mod vk {
    pub const ESCAPE: u32 = 0x1B;
    pub const CONVERT: u32 = 0x1C;
    pub const NONCONVERT: u32 = 0x1D;
    pub const RCONTROL: u32 = 0xA3;
}

/// The key that starts and stops dictation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Trigger {
    /// Right Ctrl. A modifier: its events are never swallowed.
    RightCtrl,
    /// 変換 on Japanese keyboards. Swallowed, so the IME never sees it.
    Convert,
    /// 無変換 on Japanese keyboards. Swallowed, so the IME never sees it.
    NonConvert,
}

impl Trigger {
    pub fn from_id(id: &str) -> Option<Trigger> {
        match id {
            "rightCtrl" => Some(Trigger::RightCtrl),
            "convert" => Some(Trigger::Convert),
            "nonConvert" => Some(Trigger::NonConvert),
            _ => None,
        }
    }

    fn vk(self) -> u32 {
        match self {
            Trigger::RightCtrl => vk::RCONTROL,
            Trigger::Convert => vk::CONVERT,
            Trigger::NonConvert => vk::NONCONVERT,
        }
    }

    /// Modifier events are never swallowed: doing so desynchronises the system's modifier state.
    /// Ordinary keys are, so the focused app doesn't act on them.
    fn swallows(self) -> bool {
        !matches!(self, Trigger::RightCtrl)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Pressed,
    Released,
    /// Another key was pressed while the trigger was held (e.g. Ctrl+C). Recording should be cancelled.
    Interrupted,
    Escape,
}

impl Action {
    pub fn id(self) -> &'static str {
        match self {
            Action::Pressed => "pressed",
            Action::Released => "released",
            Action::Interrupted => "interrupted",
            Action::Escape => "escape",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KeyEvent {
    pub vk: u32,
    pub down: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Output {
    pub action: Option<Action>,
    /// Whether the event should be swallowed so the focused app never sees it.
    pub consume: bool,
}

const PASS: Output = Output { action: None, consume: false };

/// Keys that change modifier or lock state rather than type something. Pressing one while holding the trigger
/// is not a shortcut yet, so it doesn't cancel (macOS sees these as flag changes, not key presses).
fn is_modifier(vk: u32) -> bool {
    matches!(vk, 0x10..=0x12 | 0x14 | 0x5B | 0x5C | 0xA0..=0xA5)
}

pub struct Interpreter {
    pub trigger: Trigger,
    /// Set while a recording is active so Esc can be swallowed only then.
    pub recording: bool,
    /// Whether the trigger is down and still counts as the hotkey (no other key pressed since).
    held: bool,
    /// Physical key state, to tell auto-repeat from new presses. The low-level hook doesn't flag repeats.
    down: [bool; 256],
}

impl Interpreter {
    pub fn new(trigger: Trigger) -> Self {
        Interpreter { trigger, recording: false, held: false, down: [false; 256] }
    }

    pub fn set_trigger(&mut self, trigger: Trigger) {
        if trigger != self.trigger {
            self.trigger = trigger;
            self.held = false;
        }
    }

    pub fn handle(&mut self, event: KeyEvent) -> Output {
        let index = (event.vk & 0xFF) as usize;
        let repeat = event.down && self.down[index];
        self.down[index] = event.down;

        if event.down && !repeat && event.vk == vk::ESCAPE && self.recording {
            self.held = false;
            return Output { action: Some(Action::Escape), consume: true };
        }

        let consume = self.trigger.swallows();
        if event.vk == self.trigger.vk() {
            if event.down {
                if repeat || self.held {
                    return Output { action: None, consume };
                }
                self.held = true;
                return Output { action: Some(Action::Pressed), consume };
            }
            if self.held {
                self.held = false;
                return Output { action: Some(Action::Released), consume };
            }
            // Interrupted earlier: letting go is not an action, but a swallowed key's up is swallowed too.
            return Output { action: None, consume };
        }

        if event.down && !repeat && self.held && !is_modifier(event.vk) {
            self.held = false;
            return Output { action: Some(Action::Interrupted), consume: false };
        }
        PASS
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const C: u32 = 0x43;
    const LSHIFT: u32 = 0xA0;
    const VOLUME_UP: u32 = 0xAF;

    fn down(vk: u32) -> KeyEvent {
        KeyEvent { vk, down: true }
    }
    fn up(vk: u32) -> KeyEvent {
        KeyEvent { vk, down: false }
    }
    fn action(out: Output) -> Option<Action> {
        out.action
    }

    #[test]
    fn right_ctrl_press_and_release_pass_through() {
        let mut sut = Interpreter::new(Trigger::RightCtrl);
        assert_eq!(sut.handle(down(vk::RCONTROL)), Output { action: Some(Action::Pressed), consume: false });
        assert_eq!(sut.handle(up(vk::RCONTROL)), Output { action: Some(Action::Released), consume: false });
    }

    #[test]
    fn auto_repeat_is_not_a_new_press() {
        let mut sut = Interpreter::new(Trigger::RightCtrl);
        assert_eq!(action(sut.handle(down(vk::RCONTROL))), Some(Action::Pressed));
        assert_eq!(action(sut.handle(down(vk::RCONTROL))), None);
        assert_eq!(action(sut.handle(down(vk::RCONTROL))), None);
        assert_eq!(action(sut.handle(up(vk::RCONTROL))), Some(Action::Released));
    }

    #[test]
    fn shortcut_with_the_trigger_interrupts_and_release_is_silent() {
        let mut sut = Interpreter::new(Trigger::RightCtrl);
        sut.handle(down(vk::RCONTROL));
        assert_eq!(sut.handle(down(C)), Output { action: Some(Action::Interrupted), consume: false });
        assert_eq!(action(sut.handle(up(C))), None);
        // Repeats of the still-held trigger after the interruption don't start a new recording.
        assert_eq!(action(sut.handle(down(vk::RCONTROL))), None);
        assert_eq!(action(sut.handle(up(vk::RCONTROL))), None);
    }

    #[test]
    fn media_keys_interrupt_but_modifiers_do_not() {
        let mut sut = Interpreter::new(Trigger::RightCtrl);
        sut.handle(down(vk::RCONTROL));
        assert_eq!(action(sut.handle(down(LSHIFT))), None);
        assert_eq!(action(sut.handle(up(LSHIFT))), None);
        assert_eq!(action(sut.handle(down(VOLUME_UP))), Some(Action::Interrupted));
    }

    #[test]
    fn a_key_held_before_the_trigger_does_not_interrupt_with_its_repeats() {
        let mut sut = Interpreter::new(Trigger::RightCtrl);
        sut.handle(down(C));
        sut.handle(down(vk::RCONTROL));
        assert_eq!(action(sut.handle(down(C))), None);
    }

    #[test]
    fn escape_is_swallowed_only_while_recording() {
        let mut sut = Interpreter::new(Trigger::RightCtrl);
        assert_eq!(sut.handle(down(vk::ESCAPE)), PASS);
        sut.handle(up(vk::ESCAPE));
        sut.recording = true;
        assert_eq!(sut.handle(down(vk::ESCAPE)), Output { action: Some(Action::Escape), consume: true });
    }

    #[test]
    fn key_triggers_are_swallowed_both_ways() {
        let mut sut = Interpreter::new(Trigger::NonConvert);
        assert_eq!(sut.handle(down(vk::NONCONVERT)), Output { action: Some(Action::Pressed), consume: true });
        assert_eq!(sut.handle(down(vk::NONCONVERT)), Output { action: None, consume: true });
        assert_eq!(sut.handle(up(vk::NONCONVERT)), Output { action: Some(Action::Released), consume: true });
        // Right Ctrl is just another key now.
        assert_eq!(sut.handle(down(vk::RCONTROL)), PASS);
    }

    #[test]
    fn key_trigger_up_after_an_interruption_is_still_swallowed() {
        let mut sut = Interpreter::new(Trigger::Convert);
        sut.handle(down(vk::CONVERT));
        assert_eq!(action(sut.handle(down(C))), Some(Action::Interrupted));
        assert_eq!(sut.handle(up(vk::CONVERT)), Output { action: None, consume: true });
    }

    #[test]
    fn changing_the_trigger_resets_the_hold() {
        let mut sut = Interpreter::new(Trigger::RightCtrl);
        sut.handle(down(vk::RCONTROL));
        sut.set_trigger(Trigger::Convert);
        assert_eq!(action(sut.handle(up(vk::RCONTROL))), None);
        assert_eq!(Trigger::from_id("nonConvert"), Some(Trigger::NonConvert));
        assert_eq!(Trigger::from_id("fn"), None);
    }
}
