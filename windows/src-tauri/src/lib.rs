//! HibiVo for Windows. The Rust side only provides what the operating system owns: the global hotkey, the
//! microphone, pasting into the focused app, Credential Manager and the HUD window. Dictation itself (the state
//! machine, Soniox, cleanup) runs in TypeScript in the main window; see `src/core`.

#[cfg(not(windows))]
compile_error!("HibiVo for Windows builds only on Windows. The macOS app lives at the repository root.");

mod audio;
mod foreground;
mod hotkey;
mod hud;
mod paste;
mod secrets;

use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, WindowEvent};

pub(crate) const MAIN_WINDOW: &str = "main";
pub(crate) const HUD_WINDOW: &str = "hud";

fn show_settings(app: &AppHandle) {
    if let Some(window) = app.get_webview_window(MAIN_WINDOW) {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

#[tauri::command]
fn open_settings(app: AppHandle) {
    show_settings(&app);
}

pub fn run() {
    tauri::Builder::default()
        // Two copies would both hook the keyboard and paste twice.
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| show_settings(app)))
        .plugin(tauri_plugin_store::Builder::new().build())
        .plugin(tauri_plugin_http::init())
        .manage(audio::AudioState::default())
        .invoke_handler(tauri::generate_handler![
            open_settings,
            audio::audio_start,
            audio::audio_stop,
            hotkey::hotkey_configure,
            hud::hud_set_visible,
            paste::paste_text,
            secrets::secret_get,
            secrets::secret_set,
        ])
        .setup(|app| {
            let handle = app.handle().clone();
            hud::prepare(&handle);
            hotkey::install(handle.clone());

            let settings = MenuItem::with_id(app, "settings", "設定を開く", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "HibiVo を終了", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&settings, &quit])?;
            let mut tray = TrayIconBuilder::with_id("main")
                .tooltip("HibiVo")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "settings" => show_settings(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left, button_state: MouseButtonState::Up, ..
                    } = event
                    {
                        show_settings(tray.app_handle());
                    }
                });
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            tray.build(app)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            // Closing the settings window keeps HibiVo running in the tray, like the menu bar app on macOS.
            if let WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == MAIN_WINDOW {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running HibiVo");
}
