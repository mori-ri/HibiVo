//! Which window has focus, described the way the dictation controller needs it.

use serde::Serialize;
use windows_sys::Win32::Foundation::{CloseHandle, HWND};
use windows_sys::Win32::System::Threading::{
    GetCurrentProcessId, OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TargetApp {
    /// The window handle as a number, so it survives the trip through JavaScript.
    pub hwnd: isize,
    pub pid: u32,
    /// Executable name without extension, e.g. "slack".
    pub name: String,
    /// One of HibiVo's own windows.
    pub is_self: bool,
}

pub fn foreground_window() -> HWND {
    unsafe { GetForegroundWindow() }
}

pub fn process_of(hwnd: HWND) -> u32 {
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(hwnd, &mut pid) };
    pid
}

pub fn describe(hwnd: HWND) -> Option<TargetApp> {
    if hwnd.is_null() {
        return None;
    }
    let pid = process_of(hwnd);
    if pid == 0 {
        return None;
    }
    Some(TargetApp {
        hwnd: hwnd as isize,
        pid,
        name: process_name(pid).unwrap_or_default(),
        is_self: pid == unsafe { GetCurrentProcessId() },
    })
}

fn process_name(pid: u32) -> Option<String> {
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return None;
        }
        let mut buffer = [0u16; 1024];
        let mut length = buffer.len() as u32;
        let ok = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, buffer.as_mut_ptr(), &mut length);
        CloseHandle(process);
        if ok == 0 {
            return None;
        }
        let path = String::from_utf16_lossy(&buffer[..length as usize]);
        let file = path.rsplit(['\\', '/']).next()?;
        Some(file.strip_suffix(".exe").or_else(|| file.strip_suffix(".EXE")).unwrap_or(file).to_string())
    }
}
