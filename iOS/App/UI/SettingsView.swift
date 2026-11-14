import SwiftUI

struct SettingsView: View {
    let environment: MobileEnvironment

    @State private var confirmsClearingHistory = false

    private var transcriptionProvider: (any TranscriptionProvider)? { environment.dictation.transcriptionProvider }

    var body: some View {
        @Bindable var settings = environment.settings
        NavigationStack {
            Form {
                transcription(settings)
                cleanup(settings)
                Section {
                    Picker("マイクを自動でオフにする", selection: $settings.standbyMinutes) {
                        ForEach(MobileSettings.standbyChoices, id: \.self) { minutes in
                            Text("\(minutes) 分後").tag(minutes)
                        }
                    }
                } header: {
                    Text("マイク")
                } footer: {
                    Text("マイクがオンの間、このアプリはバックグラウンドで動き続け、画面の上にマイクの印が出ます。音声は、キーボードのマイクを押してから止めるまでの間だけ文字起こしに使います。")
                }
                Section {
                    Toggle("履歴を残す", isOn: $settings.historyEnabled)
                    Button("履歴を消去", role: .destructive) { confirmsClearingHistory = true }
                        .disabled(environment.history.records.isEmpty)
                } header: {
                    Text("履歴")
                } footer: {
                    Text("履歴はこの iPhone の中だけに保存します。音声は保存しません。")
                }
                Section {
                    LabeledContent("バージョン", value: Self.version)
                }
            }
            .navigationTitle("設定")
            .confirmationDialog("履歴をすべて消去しますか?", isPresented: $confirmsClearingHistory, titleVisibility: .visible) {
                Button("消去", role: .destructive) { environment.history.removeAll() }
            }
        }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    // MARK: - Transcription

    private func transcription(_ settings: MobileSettings) -> some View {
        @Bindable var settings = settings
        return Section {
            Picker("サービス", selection: $settings.transcriptionProviderID) {
                ForEach(environment.transcriptionProviders, id: \.id) { provider in
                    Text(provider.displayName).tag(provider.id)
                }
            }
            Picker("話す言語", selection: $settings.language) {
                Text("日本語").tag("ja")
                Text("English").tag("en")
            }
            if let provider = transcriptionProvider, provider.requiresAPIKey {
                SecretField(title: "API Key", account: provider.id, secrets: environment.secrets)
                    .id(provider.id)
            }
            switch environment.speechModel {
            case .downloading:
                Label("音声認識モデルを準備しています…", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            case .unavailable:
                Label("この言語の音声認識モデルを用意できませんでした", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            case .ready, nil:
                EmptyView()
            }
        } header: {
            Text("文字起こし")
        } footer: {
            if let provider = transcriptionProvider, !provider.requiresAPIKey {
                Text("音声は iPhone の中で処理し、外部には送りません。")
            } else {
                Text("音声は選んだサービスに送って処理します。API Key はこの iPhone のキーチェーンに保存します。")
            }
        }
        .onChange(of: settings.transcriptionProviderID) { Task { await environment.prepareSpeechModel() } }
        .onChange(of: settings.language) { Task { await environment.prepareSpeechModel() } }
    }

    // MARK: - Cleanup

    private func cleanup(_ settings: MobileSettings) -> some View {
        @Bindable var settings = settings
        let kind = settings.cleanupProviderKind
        return Section {
            Toggle("AI 整形", isOn: $settings.cleanupEnabled)
            if settings.cleanupEnabled {
                Picker("モード", selection: $settings.cleanupMode) {
                    ForEach(CleanupMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                if settings.cleanupMode == .custom {
                    TextField(
                        "カスタム指示（例: 語尾は「です・ます」にする）",
                        text: Binding(
                            get: { settings.customCleanupInstructions },
                            set: { settings.setCustomCleanupInstructions($0) }),
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                }
                if settings.cleanupMode != .raw {
                    Picker("サービス", selection: $settings.cleanupProviderID) {
                        ForEach(CleanupProviderKind.allCases) { kind in
                            Text(kind.displayName).tag(kind.rawValue)
                        }
                    }
                    SecretField(title: "API Key", account: kind.secretAccount, secrets: environment.secrets)
                        .id(kind.secretAccount)
                    if kind == .openAICompatible {
                        TextField("Base URL", text: $settings.openAIBaseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if kind == .bedrock {
                        TextField(
                            "リージョン", text: $settings.bedrockRegion,
                            prompt: Text(verbatim: BedrockCleanupProvider.defaultRegion)
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                    TextField(
                        "モデル", text: $settings.cleanupModel,
                        prompt: Text(verbatim: kind.defaultModel.isEmpty ? "model-id" : kind.defaultModel)
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
            }
        } header: {
            Text("AI 整形")
        } footer: {
            if settings.cleanupEnabled {
                Text(settings.cleanupMode.summary)
            } else {
                Text("オンにすると、フィラーや言い直しを AI が取り除いてから入力します。文字起こしの結果を選んだサービスに送ります。")
            }
        }
    }
}

/// An API key field backed by the Keychain. The key is saved when the field loses focus or goes away,
/// not on every keystroke.
private struct SecretField: View {
    var title: LocalizedStringKey
    var account: String
    var secrets: any SecretStore

    @State private var text = ""
    @State private var saved = ""
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        SecureField(title, text: $text)
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focused)
            .onAppear {
                saved = secrets.secret(for: account) ?? ""
                text = saved
            }
            .onChange(of: focused) { if !focused { save() } }
            .onSubmit(save)
            .onDisappear(perform: save)
            .alert("API Key を保存できませんでした", isPresented: $failed) {}
    }

    private func save() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != saved else { return }
        do {
            try secrets.setSecret(value, for: account)
            saved = value
        } catch {
            failed = true
        }
    }
}
