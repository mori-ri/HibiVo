/**
 * WebView2 may throttle or freeze a hidden page. HibiVo's windows are hidden most of the time but must react at
 * once (the main window runs dictation, the HUD must draw when shown), so each holds a Web Lock forever: Chromium
 * doesn't freeze pages that hold one. The browser arguments in tauri.conf.json turn off timer throttling as well.
 */
export function keepAwake(name: string): void {
  navigator.locks?.request(name, () => new Promise<never>(() => {})).catch(() => {});
}
