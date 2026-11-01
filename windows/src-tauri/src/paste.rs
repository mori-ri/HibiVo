//! Pastes text at the caret of the focused app: clipboard + Ctrl+V, which works in Electron apps, browsers and
//! terminals alike. The user's clipboard is snapshotted first and put back afterwards if nothing else touched it.

use std::thread;
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Manager};
use windows_sys::Win32::Foundation::{CloseHandle, GlobalFree, HANDLE, HWND};
use windows_sys::Win32::Security::{GetTokenInformation, TokenElevation, TOKEN_ELEVATION, TOKEN_QUERY};
use windows_sys::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, EnumClipboardFormats, GetClipboardData, GetClipboardSequenceNumber,
    IsClipboardFormatAvailable, OpenClipboard, RegisterClipboardFormatW, SetClipboardData,
};
use windows_sys::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};
use windows_sys::Win32::System::Threading::{
    GetCurrentProcess, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, VK_CONTROL,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{IsWindow, SetForegroundWindow};

use crate::foreground;
use crate::MAIN_WINDOW;

const CF_UNICODETEXT: u32 = 13;
/// Clipboard formats backed by GDI handles or synthesized by Windows, which can't be copied as bytes.
/// Windows recreates the synthesized ones (CF_TEXT, CF_OEMTEXT, CF_LOCALE, CF_BITMAP…) from what we restore.
const SKIPPED_FORMATS: [u32; 11] = [1, 2, 3, 7, 9, 14, 16, 0x80, 0x82, 0x83, 0x8E];
/// Restore the user's clipboard this long after the paste, unless something else changed it meanwhile.
const RESTORE_DELAY: Duration = Duration::from_millis(350);
const VK_V: u16 = 0x56;

#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PasteOutcome {
    Pasted,
    CopiedOnly { reason: String },
}

/// Pastes `text` into the focused app. When one of HibiVo's own windows is in front, `target_hwnd` (the app from
/// when recording started) is brought back first.
#[tauri::command]
pub async fn paste_text(app: AppHandle, text: String, target_hwnd: Option<isize>) -> Result<PasteOutcome, String> {
    let owner = app
        .get_webview_window(MAIN_WINDOW)
        .and_then(|w| w.hwnd().ok())
        .map(|h| h.0 as isize)
        .ok_or("main window missing")?;
    tauri::async_runtime::spawn_blocking(move || paste(owner as HWND, &text, target_hwnd.map(|h| h as HWND)))
        .await
        .map_err(|e| e.to_string())?
}

fn paste(owner: HWND, text: &str, target: Option<HWND>) -> Result<PasteOutcome, String> {
    let mut front = foreground::foreground_window();
    if let Some(app) = foreground::describe(front) {
        if app.is_self {
            match target {
                Some(target) if unsafe { IsWindow(target) } != 0 => {
                    unsafe { SetForegroundWindow(target) };
                    thread::sleep(Duration::from_millis(80));
                    front = foreground::foreground_window();
                }
                _ => return copy_only(owner, text, "貼り付け先のアプリが見つかりません"),
            }
        }
    }
    if front.is_null() {
        return copy_only(owner, text, "貼り付け先のアプリが見つかりません");
    }
    // Windows drops input sent to an app running as administrator from one that isn't, without saying so.
    if is_elevated(foreground::process_of(front)) && !is_elevated_self() {
        return copy_only(owner, text, "管理者として実行中のアプリには貼り付けできません");
    }

    let snapshot = {
        let clipboard = Clipboard::open(owner)?;
        let snapshot = clipboard.snapshot();
        clipboard.write_text(text, true)?;
        snapshot
    };
    let sequence = unsafe { GetClipboardSequenceNumber() };
    if !send_ctrl_v() {
        return Ok(PasteOutcome::CopiedOnly { reason: "キー入力を送れませんでした".into() });
    }

    let owner = owner as isize;
    thread::spawn(move || {
        thread::sleep(RESTORE_DELAY);
        // Something else wrote to the clipboard meanwhile (the user copied, or the app is still reading ours).
        if unsafe { GetClipboardSequenceNumber() } != sequence {
            return;
        }
        match Clipboard::open(owner as HWND) {
            Ok(clipboard) => clipboard.restore(&snapshot),
            Err(error) => log::warn!("Clipboard restore skipped: {error}"),
        }
    });
    Ok(PasteOutcome::Pasted)
}

fn copy_only(owner: HWND, text: &str, reason: &str) -> Result<PasteOutcome, String> {
    Clipboard::open(owner)?.write_text(text, false)?;
    Ok(PasteOutcome::CopiedOnly { reason: reason.into() })
}

fn send_ctrl_v() -> bool {
    let key = |vk: u16, up: bool| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: vk,
                wScan: 0,
                dwFlags: if up { KEYEVENTF_KEYUP } else { 0 },
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    let inputs = [key(VK_CONTROL, false), key(VK_V, false), key(VK_V, true), key(VK_CONTROL, true)];
    let sent = unsafe { SendInput(inputs.len() as u32, inputs.as_ptr(), std::mem::size_of::<INPUT>() as i32) };
    sent == inputs.len() as u32
}

fn is_elevated_self() -> bool {
    unsafe { token_elevated(GetCurrentProcess()) }.unwrap_or(false)
}

/// An app whose token can't even be read is treated as elevated: that is what blocks the paste.
fn is_elevated(pid: u32) -> bool {
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return true;
        }
        let elevated = token_elevated(process);
        CloseHandle(process);
        elevated.unwrap_or(true)
    }
}

unsafe fn token_elevated(process: HANDLE) -> Option<bool> {
    let mut token: HANDLE = std::ptr::null_mut();
    if OpenProcessToken(process, TOKEN_QUERY, &mut token) == 0 {
        return None;
    }
    let mut elevation = TOKEN_ELEVATION { TokenIsElevated: 0 };
    let mut size = 0u32;
    let ok = GetTokenInformation(
        token,
        TokenElevation,
        &mut elevation as *mut _ as *mut _,
        std::mem::size_of::<TOKEN_ELEVATION>() as u32,
        &mut size,
    );
    CloseHandle(token);
    (ok != 0).then_some(elevation.TokenIsElevated != 0)
}

/// Every format on the clipboard, as bytes.
struct Snapshot(Vec<(u32, Vec<u8>)>);

/// The clipboard, open until dropped.
struct Clipboard;

impl Clipboard {
    fn open(owner: HWND) -> Result<Clipboard, String> {
        // Another app may hold it for a moment (clipboard managers do); retry briefly.
        for _ in 0..10 {
            if unsafe { OpenClipboard(owner) } != 0 {
                return Ok(Clipboard);
            }
            thread::sleep(Duration::from_millis(15));
        }
        Err("クリップボードを開けませんでした".into())
    }

    fn snapshot(&self) -> Snapshot {
        let mut formats = Vec::new();
        let has_unicode = unsafe { IsClipboardFormatAvailable(CF_UNICODETEXT) } != 0;
        let mut format = 0u32;
        loop {
            format = unsafe { EnumClipboardFormats(format) };
            if format == 0 {
                break;
            }
            if SKIPPED_FORMATS.contains(&format) && (has_unicode || format != 1) {
                continue;
            }
            if let Some(bytes) = unsafe { read_global(GetClipboardData(format)) } {
                formats.push((format, bytes));
            }
        }
        Snapshot(formats)
    }

    /// - Parameter transient: keep it out of clipboard history (Win+V) and cloud sync, like the macOS app marks its
    ///   own writes with `org.nspasteboard.TransientType`.
    fn write_text(&self, text: &str, transient: bool) -> Result<(), String> {
        unsafe { EmptyClipboard() };
        let mut utf16: Vec<u16> = text.encode_utf16().collect();
        utf16.push(0);
        let bytes = unsafe { std::slice::from_raw_parts(utf16.as_ptr() as *const u8, utf16.len() * 2) };
        set_global(CF_UNICODETEXT, bytes)?;
        if transient {
            let zero = 0u32.to_le_bytes();
            for name in [
                "ExcludeClipboardContentFromMonitorProcessing",
                "CanIncludeInClipboardHistory",
                "CanUploadToCloudClipboard",
            ] {
                let format = register_format(name);
                if format != 0 {
                    let _ = set_global(format, &zero);
                }
            }
        }
        Ok(())
    }

    fn restore(&self, snapshot: &Snapshot) {
        unsafe { EmptyClipboard() };
        for (format, bytes) in &snapshot.0 {
            if let Err(error) = set_global(*format, bytes) {
                log::warn!("Could not restore clipboard format {format}: {error}");
            }
        }
    }
}

impl Drop for Clipboard {
    fn drop(&mut self) {
        unsafe { CloseClipboard() };
    }
}

fn register_format(name: &str) -> u32 {
    let wide: Vec<u16> = name.encode_utf16().chain([0]).collect();
    unsafe { RegisterClipboardFormatW(wide.as_ptr()) }
}

unsafe fn read_global(handle: HANDLE) -> Option<Vec<u8>> {
    if handle.is_null() {
        return None;
    }
    let size = GlobalSize(handle);
    let pointer = GlobalLock(handle) as *const u8;
    if pointer.is_null() {
        return None;
    }
    let bytes = std::slice::from_raw_parts(pointer, size).to_vec();
    GlobalUnlock(handle);
    Some(bytes)
}

fn set_global(format: u32, bytes: &[u8]) -> Result<(), String> {
    unsafe {
        let memory = GlobalAlloc(GMEM_MOVEABLE, bytes.len().max(1));
        if memory.is_null() {
            return Err("GlobalAlloc failed".into());
        }
        let pointer = GlobalLock(memory) as *mut u8;
        if pointer.is_null() {
            GlobalFree(memory);
            return Err("GlobalLock failed".into());
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), pointer, bytes.len());
        GlobalUnlock(memory);
        // On success the clipboard owns the memory.
        if SetClipboardData(format, memory as HANDLE).is_null() {
            GlobalFree(memory);
            return Err("SetClipboardData failed".into());
        }
        Ok(())
    }
}
