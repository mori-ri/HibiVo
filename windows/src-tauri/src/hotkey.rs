//! The global dictation hotkey: a low-level keyboard hook on its own thread.
//!
//! The hook callback must return quickly or Windows silently removes the hook, so it only interprets the key (which
//! has to happen synchronously to decide whether to swallow it) and hands the action to another thread, which looks
//! up the focused app and emits it to the main window.

use std::sync::mpsc::{self, Sender};
use std::sync::{Mutex, OnceLock};
use std::thread;

use hibivo_core::hotkey::{Action, Interpreter, KeyEvent, Trigger};
use serde::Serialize;
use tauri::{AppHandle, Emitter};
use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, DispatchMessageW, GetMessageW, SetWindowsHookExW, TranslateMessage, HC_ACTION, KBDLLHOOKSTRUCT,
    LLKHF_INJECTED, MSG, WH_KEYBOARD_LL, WM_KEYDOWN, WM_SYSKEYDOWN,
};

use crate::foreground::{self, TargetApp};
use crate::MAIN_WINDOW;

struct Shared {
    interpreter: Mutex<Interpreter>,
    sender: Mutex<Sender<Fired>>,
}

struct Fired {
    action: Action,
    time: u32,
    hwnd: isize,
}

#[derive(Clone, Serialize)]
struct HotkeyPayload {
    action: &'static str,
    /// Event time on the system tick clock, in milliseconds.
    time: u32,
    foreground: Option<TargetApp>,
}

static SHARED: OnceLock<Shared> = OnceLock::new();

pub fn install(app: AppHandle) {
    let (sender, receiver) = mpsc::channel::<Fired>();
    let shared = Shared { interpreter: Mutex::new(Interpreter::new(Trigger::RightCtrl)), sender: Mutex::new(sender) };
    if SHARED.set(shared).is_err() {
        return;
    }

    thread::Builder::new()
        .name("hotkey-emit".into())
        .spawn(move || {
            for fired in receiver {
                let payload = HotkeyPayload {
                    action: fired.action.id(),
                    time: fired.time,
                    foreground: foreground::describe(fired.hwnd as HWND),
                };
                if let Err(error) = app.emit_to(MAIN_WINDOW, "hotkey", payload) {
                    log::error!("Failed to emit hotkey: {error}");
                }
            }
        })
        .expect("failed to start the hotkey thread");

    thread::Builder::new()
        .name("hotkey-hook".into())
        .spawn(|| unsafe {
            let hook = SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook_proc), GetModuleHandleW(std::ptr::null()), 0);
            if hook.is_null() {
                log::error!("SetWindowsHookExW failed; the hotkey will not work");
                return;
            }
            // Low-level hooks are called on the installing thread, which must pump messages.
            let mut message: MSG = std::mem::zeroed();
            while GetMessageW(&mut message, std::ptr::null_mut(), 0, 0) > 0 {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        })
        .expect("failed to start the keyboard hook thread");
}

unsafe extern "system" fn hook_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let info = &*(lparam as *const KBDLLHOOKSTRUCT);
        // Our own Ctrl+V comes back through the hook; it must not count as a key press.
        if info.flags & LLKHF_INJECTED == 0 {
            if let Some(shared) = SHARED.get() {
                let message = wparam as u32;
                let event = KeyEvent { vk: info.vkCode, down: message == WM_KEYDOWN || message == WM_SYSKEYDOWN };
                let output = shared.interpreter.lock().map(|mut i| i.handle(event)).ok();
                if let Some(output) = output {
                    if let Some(action) = output.action {
                        let fired = Fired { action, time: info.time, hwnd: foreground::foreground_window() as isize };
                        if let Ok(sender) = shared.sender.lock() {
                            let _ = sender.send(fired);
                        }
                    }
                    if output.consume {
                        return 1;
                    }
                }
            }
        }
    }
    CallNextHookEx(std::ptr::null_mut(), code, wparam, lparam)
}

/// Called by the main window when the trigger setting changes and whenever recording starts or stops,
/// so Esc is swallowed only while recording.
#[tauri::command]
pub fn hotkey_configure(trigger: String, recording: bool) -> Result<(), String> {
    let trigger = Trigger::from_id(&trigger).ok_or_else(|| format!("unknown trigger {trigger}"))?;
    let shared = SHARED.get().ok_or("hotkey not installed")?;
    let mut interpreter = shared.interpreter.lock().map_err(|e| e.to_string())?;
    interpreter.set_trigger(trigger);
    interpreter.recording = recording;
    Ok(())
}
