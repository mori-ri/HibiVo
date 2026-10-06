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

        Window("HibiVo", id: WindowID.main) {
            MainWindowView(env: appDelegate.env)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 880, height: 600)
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard env.meeting.isActive else { return .terminateNow }
        env.prepareForTermination { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
