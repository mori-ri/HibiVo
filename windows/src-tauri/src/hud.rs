//! The HUD: a small always-on-top window at the bottom centre of the screen the user is working on.
//! It must never take focus, or the paste would land in it instead of the app the user is writing in.

use tauri::{AppHandle, Manager, WebviewWindow};
use windows_sys::Win32::Foundation::{HWND, RECT};
use windows_sys::Win32::Graphics::Gdi::{GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTOPRIMARY};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GetWindowLongPtrW, GetWindowRect, SetWindowLongPtrW, SetWindowPos, ShowWindow, GWL_EXSTYLE, HWND_TOPMOST,
    SWP_NOACTIVATE, SWP_NOSIZE, SWP_SHOWWINDOW, SW_HIDE, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TRANSPARENT,
};

use crate::{foreground, HUD_WINDOW};

/// Gap between the HUD and the bottom of the work area (above the taskbar), in physical pixels at 100 %.
const BOTTOM_MARGIN: f64 = 72.0;

fn hwnd(window: &WebviewWindow) -> Option<HWND> {
    window.hwnd().ok().map(|h| h.0 as HWND)
}

pub fn prepare(app: &AppHandle) {
    let Some(window) = app.get_webview_window(HUD_WINDOW) else { return };
    let _ = window.set_ignore_cursor_events(true);
    if let Some(hwnd) = hwnd(&window) {
        unsafe {
            let style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
            let extra = (WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT) as isize;
            SetWindowLongPtrW(hwnd, GWL_EXSTYLE, style | extra);
        }
    }
}

#[tauri::command]
pub fn hud_set_visible(app: AppHandle, visible: bool) {
    let Some(window) = app.get_webview_window(HUD_WINDOW) else { return };
    let Some(hud) = hwnd(&window) else { return };
    unsafe {
        if !visible {
            ShowWindow(hud, SW_HIDE);
            return;
        }
        let monitor = MonitorFromWindow(foreground::foreground_window(), MONITOR_DEFAULTTOPRIMARY);
        let mut info: MONITORINFO = std::mem::zeroed();
        info.cbSize = std::mem::size_of::<MONITORINFO>() as u32;
        if GetMonitorInfoW(monitor, &mut info) == 0 {
            return;
        }
        let mut rect: RECT = std::mem::zeroed();
        GetWindowRect(hud, &mut rect);
        let width = rect.right - rect.left;
        let height = rect.bottom - rect.top;
        let scale = window.scale_factor().unwrap_or(1.0);
        let work = info.rcWork;
        let x = work.left + (work.right - work.left - width) / 2;
        let y = work.bottom - height - (BOTTOM_MARGIN * scale) as i32;
        // Show without activating: the app the user is dictating into keeps focus.
        SetWindowPos(hud, HWND_TOPMOST, x, y, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }
}
