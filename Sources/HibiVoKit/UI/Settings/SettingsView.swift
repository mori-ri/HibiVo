import ServiceManagement
import SwiftUI

public struct SettingsView: View {
    let env: AppEnvironment

    public init(env: AppEnvironment) {
        self.env = env
    }

    public var body: some View {
        TabView {
            GeneralSettingsView(env: env).tabItem { Label("一般", systemImage: "gearshape") }
            TranscriptionSettingsView(env: env).tabItem { Label("文字起こし", systemImage: "waveform") }
            CleanupSettingsView(env: env).tabItem { Label("AI 整形", systemImage: "sparkles") }
            VocabularySettingsView(store: env.vocabulary).tabItem { Label("辞書", systemImage: "character.book.closed") }
            ApplicationSettingsView(settings: env.settings).tabItem { Label("アプリ", systemImage: "square.grid.2x2") }
        }
        .frame(width: 560, height: 440)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    let env: AppEnvironment
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String? = nil

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section {
                Toggle("ログイン時に起動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let launchError { Text(launchError).font(.caption).foregroundStyle(.red) }
            }
            Section("操作") {
                Picker("ホットキー（押している間だけ録音）", selection: hotkeyBinding) {
                    ForEach(HotkeyTrigger.presets, id: \.self) { Text($0.displayName).tag($0) }
                }
                if env.settings.hotkey == .fn {
                    Text("システム設定 › キーボード の「🌐キーを押して」を「何もしない」にしてください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Esc で録音を取り消せます。").font(.caption).foregroundStyle(.secondary)
            }
            Section("音声") {
                Picker("マイク", selection: $settings.microphoneUID) {
                    Text("システム既定").tag(String?.none)
                    ForEach(AudioDeviceCatalog.inputDevices()) { Text($0.name).tag(Optional($0.uid)) }
                }
            }
            Section {
                Toggle("履歴を保存する", isOn: $settings.historyEnabled)
            } header: {
                Text("履歴")
            } footer: {
                Text("文字起こしと整形結果のテキストを、この Mac の中に最大 \(HistoryStore.limit) 件保存します。音声は保存しません。")
            }
            Section("権限") {
                PermissionRow(title: "アクセシビリティ（ホットキー・貼り付け）", granted: env.state.hasAccessibilityPermission) {
                    Permissions.openAccessibilitySettings()
                }
                PermissionRow(title: "マイク", granted: env.state.hasMicrophonePermission) {
                    Permissions.openMicrophoneSettings()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var hotkeyBinding: Binding<HotkeyTrigger> {
        Binding(get: { env.settings.hotkey }, set: { env.applyHotkey($0) })
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = "設定できませんでした。HibiVo.app を「アプリケーション」フォルダに置いてください。"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let open: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            Spacer()
            if !granted { Button("許可する…", action: open) }
        }
    }
}

// MARK: - Transcription

struct TranscriptionSettingsView: View {
    let env: AppEnvironment

    var body: some View {
        @Bindable var settings = env.settings
        let provider = env.transcriptionProviders.first { $0.id == settings.transcriptionProviderID }
        Form {
            Section {
                Picker("STT Provider", selection: $settings.transcriptionProviderID) {
                    ForEach(env.transcriptionProviders, id: \.id) { Text($0.displayName).tag($0.id) }
                }
                if let provider {
                    APIKeyField(secrets: env.secrets, account: provider.id, label: "\(provider.displayName) API Key")
                    Picker("モデル", selection: $settings.transcriptionModel) {
                        Text("既定（\(provider.defaultModel)）").tag("")
                        ForEach(provider.models, id: \.self) { Text($0).tag($0) }
                    }
                }
                Picker("言語", selection: $settings.language) {
                    Text("日本語").tag("ja")
                    Text("English").tag("en")
                }
            } footer: {
                Text("話している間にストリーミングで文字起こしします。音声は保存されません。")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Cleanup

struct CleanupSettingsView: View {
    let env: AppEnvironment

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section {
                Toggle("AI で文章を整える", isOn: $settings.cleanupEnabled)
                Picker("既定のモード", selection: $settings.defaultCleanupMode) {
                    ForEach(CleanupMode.allCases) { Text($0.displayName).tag($0) }
                }
            } footer: {
                Text("整形に失敗したときは、文字起こし結果をそのまま入力します。")
            }
            Section("LLM") {
                Picker("Provider", selection: $settings.cleanupProviderID) {
                    Text("Anthropic (Claude)").tag("anthropic")
                    Text("OpenAI 互換").tag("openai-compatible")
                }
                if settings.cleanupProviderID == "openai-compatible" {
                    TextField("Base URL", text: $settings.openAIBaseURL, prompt: Text(OpenAICompatibleCleanupProvider.defaultBaseURL))
                    TextField("モデル", text: $settings.cleanupModel, prompt: Text("例: gpt-4.1-mini"))
                    APIKeyField(secrets: env.secrets, account: "openai-compatible", label: "API Key")
                } else {
                    TextField("モデル", text: $settings.cleanupModel, prompt: Text("既定: claude-opus-5"))
                    APIKeyField(secrets: env.secrets, account: "anthropic", label: "Anthropic API Key")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Reads and writes an API key straight to the Keychain. Nothing touches UserDefaults.
struct APIKeyField: View {
    let secrets: any SecretStore
    let account: String
    let label: String
    @State private var value = ""
    @State private var saved = false

    var body: some View {
        HStack {
            SecureField(label, text: $value)
                .onSubmit(save)
            Button(saved ? "保存済み" : "保存", action: save)
                .disabled(saved)
        }
        .onAppear { load() }
        .onChange(of: account) { load() }
        .onChange(of: value) { saved = value == (secrets.secret(for: account) ?? "") }
    }

    private func load() {
        value = secrets.secret(for: account) ?? ""
        saved = true
    }

    private func save() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try? secrets.setSecret(trimmed.isEmpty ? nil : trimmed, for: account)
        value = trimmed
        saved = true
    }
}
