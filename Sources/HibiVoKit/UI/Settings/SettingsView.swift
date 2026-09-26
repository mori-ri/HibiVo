import ServiceManagement
import SwiftUI

// MARK: - General

struct GeneralSettingsView: View {
    let env: AppEnvironment
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String? = nil

    var body: some View {
        @Bindable var settings = env.settings
        SettingsPage {
            SettingsSection {
                ToggleRow("ログイン時に起動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let launchError { NoteRow(launchError, color: .red) }
            }
            SettingsSection(title: "操作") {
                PickerRow("ホットキー（押している間だけ録音）", selection: hotkeyBinding) {
                    ForEach(HotkeyTrigger.presets, id: \.self) { Text($0.displayName).tag($0) }
                }
                if env.settings.hotkey == .fn {
                    NoteRow("システム設定 › キーボード の「🌐キーを押して」を「何もしない」にしてください。")
                }
                NoteRow("Esc で録音を取り消せます。")
            }
            SettingsSection(title: "音声") {
                PickerRow("マイク", selection: $settings.microphoneUID) {
                    Text("システム既定").tag(String?.none)
                    ForEach(AudioDeviceCatalog.inputDevices()) { Text($0.name).tag(Optional($0.uid)) }
                }
            }
            SettingsSection(
                title: "履歴",
                footer: "文字起こしと整形結果のテキストを、この Mac の中に最大 \(HistoryStore.limit) 件保存します。音声は保存しません。"
            ) {
                ToggleRow("履歴を保存する", isOn: $settings.historyEnabled)
            }
            SettingsSection(title: "権限") {
                PermissionRow(title: "アクセシビリティ（ホットキー・貼り付け）", granted: env.state.hasAccessibilityPermission) {
                    Permissions.openAccessibilitySettings()
                }
                PermissionRow(title: "マイク", granted: env.state.hasMicrophonePermission) {
                    Permissions.openMicrophoneSettings()
                }
            }
        }
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
        LabeledRow {
            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                Text(title)
            }
        } control: {
            if granted {
                Text("許可済み").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("許可する…", action: open)
            }
        }
    }
}

// MARK: - Transcription

struct TranscriptionSettingsView: View {
    let env: AppEnvironment

    var body: some View {
        @Bindable var settings = env.settings
        let provider = env.transcriptionProviders.first { $0.id == settings.transcriptionProviderID }
        SettingsPage {
            SettingsSection(footer: "話している間にストリーミングで文字起こしします。音声は保存されません。") {
                PickerRow("STT Provider", selection: $settings.transcriptionProviderID) {
                    ForEach(env.transcriptionProviders, id: \.id) { Text($0.displayName).tag($0.id) }
                }
                if let provider {
                    APIKeyField(secrets: env.secrets, account: provider.id, label: "\(provider.displayName) API Key")
                    PickerRow("モデル", selection: $settings.transcriptionModel) {
                        Text("既定（\(provider.defaultModel)）").tag("")
                        ForEach(provider.models, id: \.self) { Text($0).tag($0) }
                    }
                }
                PickerRow("言語", selection: $settings.language) {
                    Text("日本語").tag("ja")
                    Text("English").tag("en")
                }
            }
        }
    }
}

// MARK: - Cleanup

struct CleanupSettingsView: View {
    let env: AppEnvironment

    var body: some View {
        @Bindable var settings = env.settings
        SettingsPage {
            SettingsSection(footer: "整形に失敗したときは、文字起こし結果をそのまま入力します。") {
                ToggleRow("AI で文章を整える", isOn: $settings.cleanupEnabled)
                PickerRow("既定のモード", selection: $settings.defaultCleanupMode) {
                    ForEach(CleanupMode.allCases) { Text($0.displayName).tag($0) }
                }
            }
            SettingsSection(title: "LLM") {
                PickerRow("Provider", selection: $settings.cleanupProviderID) {
                    ForEach(CleanupProviderKind.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                // Model names differ per provider, so go back to the new provider's default.
                .onChange(of: settings.cleanupProviderID) { settings.cleanupModel = "" }

                switch CleanupProviderKind(rawValue: settings.cleanupProviderID) ?? .anthropic {
                case .anthropic:
                    TextFieldRow("モデル", text: $settings.cleanupModel, prompt: "既定: \(CleanupProviderKind.anthropic.defaultModel)")
                    APIKeyField(secrets: env.secrets, account: SecretAccount.anthropic, label: "Anthropic API Key")
                case .openAICompatible:
                    TextFieldRow("Base URL", text: $settings.openAIBaseURL, prompt: OpenAICompatibleCleanupProvider.defaultBaseURL)
                    TextFieldRow("モデル", text: $settings.cleanupModel, prompt: "例: gpt-4.1-mini")
                    APIKeyField(secrets: env.secrets, account: SecretAccount.openAICompatible, label: "API Key")
                case .bedrock:
                    BedrockSettingsFields(env: env)
                }
            }
        }
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
        LabeledRow(label) {
            SecureField(label, text: $value)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 340)
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

private struct BedrockSettingsFields: View {
    let env: AppEnvironment

    var body: some View {
        @Bindable var settings = env.settings
        TextFieldRow("リージョン", text: $settings.bedrockRegion, prompt: BedrockCleanupProvider.defaultRegion)
        LabeledRow("モデル ID") {
            TextField("モデル ID", text: $settings.cleanupModel, prompt: Text("既定: \(CleanupProviderKind.bedrock.defaultModel)"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 340)
            Menu("候補") {
                ForEach(BedrockCleanupProvider.suggestedModels, id: \.self) { model in
                    Button(model) { settings.cleanupModel = model }
                }
            }
            .fixedSize()
        }
        NoteRow("モデル ID または推論プロファイル ID を指定します。Claude は InvokeModel、それ以外（GLM、MiniMax、GPT など）は Converse API で呼び出します。")
        PickerRow("認証", selection: $settings.bedrockAuth) {
            ForEach(BedrockAuthMethod.allCases) { Text($0.displayName).tag($0) }
        }
        switch settings.bedrockAuth {
        case .apiKey:
            APIKeyField(secrets: env.secrets, account: SecretAccount.bedrockAPIKey, label: "Bedrock API キー")
        case .iam:
            APIKeyField(secrets: env.secrets, account: SecretAccount.awsAccessKeyID, label: "アクセスキー ID")
            APIKeyField(secrets: env.secrets, account: SecretAccount.awsSecretAccessKey, label: "シークレットアクセスキー")
            APIKeyField(secrets: env.secrets, account: SecretAccount.awsSessionToken, label: "セッショントークン（一時認証情報のみ）")
            NoteRow("必要な権限: bedrock:InvokeModel（Converse も同じ権限です）。認証情報は Keychain に保存されます。")
        }
    }
}
