import SwiftUI

public enum WindowID {
    public static let settings = "settings"
    public static let history = "history"
}

public struct MenuBarContent: View {
    let env: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    public init(env: AppEnvironment) {
        self.env = env
    }

    public var body: some View {
        if !env.state.hasAccessibilityPermission {
            Button("⚠️ アクセシビリティ権限を許可…") { Permissions.openAccessibilitySettings() }
        }
        if !env.state.hasMicrophonePermission {
            Button("⚠️ マイク権限を許可…") { Permissions.openMicrophoneSettings() }
        }

        Text("\(env.settings.hotkey.displayName) を押しながら話す")

        if let last = env.history.records.first(where: { !$0.finalText.isEmpty }) {
            Button("直前の結果をもう一度入力") { env.pasteAgain(last.finalText) }
        }

        Divider()

        Picker("整形モード", selection: modeBinding) {
            ForEach(CleanupMode.allCases) { Text($0.displayName).tag($0) }
        }
        Toggle("AI で整形", isOn: cleanupBinding)
        Picker("マイク", selection: microphoneBinding) {
            Text("システム既定").tag(String?.none)
            ForEach(AudioDeviceCatalog.inputDevices()) { Text($0.name).tag(Optional($0.uid)) }
        }
        Picker("STT Provider", selection: providerBinding) {
            ForEach(env.transcriptionProviders, id: \.id) { Text($0.displayName).tag($0.id) }
        }

        Divider()

        Button("履歴…") { open(WindowID.history) }
            .keyboardShortcut("y")
        Button("設定…") { open(WindowID.settings) }
            .keyboardShortcut(",")

        Divider()

        Button("HibiVo を終了") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// A menu-bar-only app has to activate itself or the window opens behind the frontmost app.
    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
    }

    private var modeBinding: Binding<CleanupMode> {
        Binding(get: { env.settings.defaultCleanupMode }, set: { env.settings.defaultCleanupMode = $0 })
    }

    private var cleanupBinding: Binding<Bool> {
        Binding(get: { env.settings.cleanupEnabled }, set: { env.settings.cleanupEnabled = $0 })
    }

    private var microphoneBinding: Binding<String?> {
        Binding(get: { env.settings.microphoneUID }, set: { env.settings.microphoneUID = $0 })
    }

    private var providerBinding: Binding<String> {
        Binding(get: { env.settings.transcriptionProviderID }, set: { env.settings.transcriptionProviderID = $0 })
    }
}

public struct MenuBarLabel: View {
    let state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        switch state.phase {
        case .idle:
            if let logo = Self.logo { Image(nsImage: logo) } else { Image(systemName: "mic") }
        case .recording: Image(systemName: "mic.fill")
        case .processing: Image(systemName: "ellipsis.circle")
        case .error: Image(systemName: "exclamationmark.triangle")
        }
    }

    /// Monochrome template from the app bundle (see scripts/make-icons.swift), so macOS can tint it
    /// for light and dark menu bars. Missing when run outside the .app, e.g. `swift run`.
    private static let logo: NSImage? = {
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        return image
    }()
}
