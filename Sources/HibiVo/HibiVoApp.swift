import HibiVoKit
import SwiftUI

@main
struct HibiVoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(env: appDelegate.env)
        } label: {
            MenuBarLabel(state: appDelegate.env.state)
        }

        Window("HibiVo 設定", id: WindowID.settings) {
            SettingsView(env: appDelegate.env)
        }
        .windowResizability(.contentSize)

        Window("HibiVo 履歴", id: WindowID.history) {
            HistoryView(env: appDelegate.env)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let env = AppEnvironment()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only; no Dock icon (also set via LSUIElement in Info.plist).
        NSApp.setActivationPolicy(.accessory)
        env.start()
    }
}
