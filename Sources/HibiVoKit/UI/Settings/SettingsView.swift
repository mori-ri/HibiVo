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
                PickerRow("ホットキー（押すと録音開始、もう一度押すと終了）", selection: hotkeyBinding) {
                    ForEach(HotkeyTrigger.presets, id: \.self) { Text($0.displayName).tag($0) }
                }
                if env.settings.hotkey == .fn {
                    NoteRow("システム設定 › キーボード の「🌐キーを押して」を「何もしない」にしてください。")
                }
                NoteRow("押し続けて話し、離して終了することもできます。Esc で録音を取り消せます。止め忘れた録音は 10 分で自動的に終了します。")
            }
            SettingsSection(title: "音声") {
                PickerRow("マイク", selection: $settings.microphoneUID) {
                    Text("システム既定").tag(String?.none)
                    ForEach(AudioDeviceCatalog.inputDevices()) { Text($0.name).tag(Optional($0.uid)) }
                }
                ToggleRow("録音中はスピーカーの音量を下げる", isOn: $settings.duckOutputWhileRecording)
                ToggleRow("話している内容をリアルタイムで表示", isOn: $settings.showLiveTranscript)
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
                // Model names differ per provider, so go back to the new provider's default.
                .onChange(of: settings.transcriptionProviderID) {
                    settings.transcriptionModel = ""
                    env.prepareSpeechModel()
                }
                if let provider, !provider.requiresAPIKey {
                    NoteRow("Mac の中で文字起こしするため、API Key は不要で料金もかかりません。音声は外部に送信されません。")
                    SpeechModelStatusRow(language: settings.language)
                } else if let provider {
                    APIKeyField(secrets: env.secrets, account: provider.id, label: "\(provider.displayName) API Key")
                    PickerRow("モデル", selection: $settings.transcriptionModel) {
                        Text("既定（\(provider.defaultModel)）").tag("")
                        ForEach(provider.models, id: \.self) { Text($0).tag($0) }
                    }
                    if provider.id == SecretAccount.gemini {
                        NoteRow("Google AI Studio の API キーを使います。AI 整形の Google Gemini と共通です。")
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

/// Shows whether macOS's speech model for the language is on this Mac, downloading it if not.
private struct SpeechModelStatusRow: View {
    let language: String
    @State private var status: AppleSpeechProvider.ModelStatus = .downloading

    var body: some View {
        Group {
            switch status {
            case .ready:
                NoteRow("音声認識モデル: 準備できています")
            case .downloading:
                NoteRow("音声認識モデルをダウンロードしています…")
            case .unavailable:
                NoteRow("この言語の音声認識モデルを用意できませんでした。ネットワークを確認するか、別の STT Provider を選んでください。", color: .red)
            }
        }
        .task(id: language) {
            status = .downloading
            status = await AppleSpeechProvider.prepareModel(language: language)
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
            }
            CleanupModeSection(
                mode: $settings.defaultCleanupMode, customInstructions: settings.customCleanupInstructions,
                onSaveCustomInstructions: settings.setCustomCleanupInstructions)
            SettingsSection(title: "LLM") {
                PickerRow("Provider", selection: $settings.cleanupProviderID) {
                    ForEach(CleanupProviderKind.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                // Model names differ per provider, so go back to the new provider's default.
                .onChange(of: settings.cleanupProviderID) { settings.cleanupModel = "" }

                switch CleanupProviderKind(rawValue: settings.cleanupProviderID) ?? .anthropic {
                case .anthropic:
                    TextFieldRow(
                        "モデル", text: $settings.cleanupModel, prompt: "既定: \(CleanupProviderKind.anthropic.defaultModel)"
                    )
                    APIKeyField(secrets: env.secrets, account: SecretAccount.anthropic, label: "Anthropic API Key")
                case .openAICompatible:
                    TextFieldRow(
                        "Base URL", text: $settings.openAIBaseURL,
                        prompt: OpenAICompatibleCleanupProvider.defaultBaseURL)
                    TextFieldRow("モデル", text: $settings.cleanupModel, prompt: "例: gpt-4.1-mini")
                    APIKeyField(secrets: env.secrets, account: SecretAccount.openAICompatible, label: "API Key")
                case .bedrock:
                    BedrockSettingsFields(env: env)
                case .gemini:
                    GeminiSettingsFields(env: env)
                }
            }
        }
    }
}

/// Picks the default mode from a list that explains each one, with a sample of the selected mode's output.
private struct CleanupModeSection: View {
    @Binding var mode: CleanupMode
    let customInstructions: String
    let onSaveCustomInstructions: (String) -> Void
    @State private var hovered: CleanupMode?
    @State private var isEditingInstructions = false

    var body: some View {
        SettingsSection(
            title: "既定のモード",
            footer:
                "サンプルは例です。実際の出力は、話した内容や使うモデルによって変わります。Custom の指示は、アプリ別モードで Custom を選んだアプリにも使われます。"
        ) {
            ForEach(CleanupMode.allCases) { option in
                row(option)
            }
        }
        .sheet(isPresented: $isEditingInstructions) {
            PromptEditorSheet(
                title: "Custom モードの指示", initialText: customInstructions,
                limit: CleanupMode.customInstructionsLimit, defaultText: nil,
                explanation: "フィラーの除去などの基本的な整形に加えて、ここに書いた指示に従います。",
                onSave: onSaveCustomInstructions)
        }
    }

    private func row(_ option: CleanupMode) -> some View {
        let isSelected = option == mode
        return SettingsRow(separatorInset: 44) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.displayName)
                            .fontWeight(isSelected ? .semibold : .regular)
                        Text(option.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if option == .custom, let preview = instructionsPreview {
                            Text("指示: \(preview)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 12)
                    if option == .custom {
                        Button("指示を編集…") { isEditingInstructions = true }
                    }
                }
                if isSelected, let output = option.sampleOutput {
                    sample(output)
                        .padding(.leading, 30)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { mode = option }
        }
        .background(hovered == option && !isSelected ? Theme.hover : .clear)
        .onHover { hovered = $0 ? option : (hovered == option ? nil : hovered) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { mode = option }
    }

    private func sample(_ output: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            sampleText("話した言葉", CleanupSample.spoken, secondary: true)
            Theme.separator.frame(height: 1)
            sampleText("整形後", output)
        }
        .overlay(shape.strokeBorder(Theme.cardStroke))
        .clipShape(shape)
    }

    private func sampleText(_ title: String, _ text: String, secondary: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var instructionsPreview: String? {
        customInstructions.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}

// MARK: - Meeting

struct MeetingSettingsView: View {
    let env: AppEnvironment

    var body: some View {
        @Bindable var settings = env.settings
        let transcriber =
            env.meetingTranscribers.first { $0.provider.id == settings.meetingTranscriptionProviderID }
            ?? env.meetingTranscribers[0]
        let identifiesSpeakers = transcriber.provider.identifiesSpeakers
        SettingsPage {
            SettingsSection(
                footer:
                    "\(env.settings.hotkey.displayName) を押しながら M で開始し、\(env.settings.hotkey.displayName) を素早く 2 回押すと終了します。Markdown で保存します。"
            ) {
                PickerRow("文字起こし", selection: $settings.meetingTranscriptionProviderID) {
                    ForEach(env.meetingTranscribers, id: \.provider.id) {
                        Text($0.provider.displayName).tag($0.provider.id)
                    }
                }
                .onChange(of: settings.meetingTranscriptionProviderID) { env.prepareSpeechModel() }
                if !transcriber.provider.requiresAPIKey {
                    NoteRow("Mac の中で文字起こしするため、API Key は不要で料金もかかりません。話者は区別しません。話者を区別するには Soniox を選んでください。")
                    SpeechModelStatusRow(language: settings.language)
                } else {
                    APIKeyField(
                        secrets: env.secrets, account: transcriber.provider.id,
                        label: "\(transcriber.provider.displayName) API Key")
                }
                if transcriber.fileTranscriber != nil {
                    PickerRow("文字起こしのタイミング", selection: $settings.meetingTranscriptionTiming) {
                        ForEach(MeetingTranscriptionTiming.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                switch transcriber.fileTranscriber == nil ? .realtime : env.settings.meetingTranscriptionTiming {
                case .realtime:
                    NoteRow(
                        identifiesSpeakers
                            ? "会議中に文字起こしし、数秒ごとにファイルへ書き足します。話者の区別はやや粗くなります。"
                            : "会議中に文字起こしし、数秒ごとにファイルへ書き足します。")
                case .afterMeeting:
                    NoteRow(
                        "会議中は録音だけを行い、終了後に音声全体から文字起こしするため、話者を正確に区別できます。結果は 1 時間の会議で数分ほどで届きます。音声は終了までメモリに置くだけで保存しないため、途中でアプリが終了するとその会議は記録されません。"
                    )
                }
                LabeledRow("保存先") {
                    Button("開く…") { env.openMeetingsFolder() }
                }
            }
            SettingsSection(title: "音声") {
                ToggleRow("オンライン参加者の声(システム音声)も記録する", isOn: $settings.meetingCapturesSystemAudio)
                if !SystemAudioCaptureService.isSupported {
                    NoteRow("システム音声の記録には macOS 14.2 以降が必要です。", color: .red)
                } else if env.settings.meetingCapturesSystemAudio {
                    NoteRow(
                        (identifiesSpeakers ? "マイクの音と混ぜて 1 本にし、全員を話者 1・2… として識別します。" : "マイクの音と混ぜて 1 本にして文字起こしします。")
                            + "初回はシステムオーディオ録音の許可を求められます。スピーカーで聞くと相手の声がマイクにも入って少しずれて重なり、認識しにくくなることがあるため、イヤホンの使用をおすすめします。"
                    )
                    LabeledRow("システムオーディオ録音の権限") {
                        Button("設定を開く…") { Permissions.openSystemAudioSettings() }
                    }
                }
            }
            SettingsSection(title: "議事録") {
                ToggleRow("終了後に Claude で議事録を作成する", isOn: $settings.meetingMinutesEnabled)
                if env.settings.meetingMinutesEnabled {
                    PickerRow("議事録のモデル", selection: $settings.meetingMinutesModel) {
                        ForEach(MeetingMinutesModel.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextFieldRow("Claude Code の場所", text: $settings.claudeCodePath, prompt: "自動で検出")
                    MinutesInstructionsRows(settings: env.settings)
                    if let path = ClaudeCodeMinutesWriter.locate(configuredPath: env.settings.claudeCodePath) {
                        NoteRow(
                            "Claude Code(\(path.path))を使い、Claude のサブスクリプションの利用枠で議事録を作成します。API の料金はかかりません。会議の内容を表すタイトルを付けて、文字起こしの隣に保存します。"
                        )
                    } else {
                        NoteRow(
                            "Claude Code が見つかりません。インストールして claude.ai のアカウントでログインするか、実行ファイルの場所を入力してください。", color: .red)
                    }
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
    @State private var savedValue = ""
    @State private var saveFailed = false

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
        .onChange(of: value) { saved = value == savedValue }
        .alert("認証情報を保存できませんでした", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("キーチェーンの状態やアクセス許可を確認して、もう一度保存してください。")
        }
    }

    private func load() {
        value = secrets.secret(for: account) ?? ""
        savedValue = value
        saved = true
    }

    private func save() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try secrets.setSecret(trimmed.isEmpty ? nil : trimmed, for: account)
            savedValue = trimmed
            value = trimmed
            saved = true
        } catch {
            saveFailed = true
        }
    }
}

private struct GeminiSettingsFields: View {
    let env: AppEnvironment

    var body: some View {
        @Bindable var settings = env.settings
        LabeledRow("モデル") {
            TextField(
                "モデル", text: $settings.cleanupModel, prompt: Text("既定: \(CleanupProviderKind.gemini.defaultModel)")
            )
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 340)
            Menu("候補") {
                ForEach(GeminiCleanupProvider.suggestedModels, id: \.self) { model in
                    Button(model) { settings.cleanupModel = model }
                }
            }
            .fixedSize()
        }
        APIKeyField(secrets: env.secrets, account: SecretAccount.gemini, label: "Google Gemini API Key")
        NoteRow("Google AI Studio の API キーを使います。文字起こしの Google Gemini と共通です。")
    }
}

private struct BedrockSettingsFields: View {
    let env: AppEnvironment

    var body: some View {
        @Bindable var settings = env.settings
        TextFieldRow("リージョン", text: $settings.bedrockRegion, prompt: BedrockCleanupProvider.defaultRegion)
        LabeledRow("モデル ID") {
            TextField(
                "モデル ID", text: $settings.cleanupModel, prompt: Text("既定: \(CleanupProviderKind.bedrock.defaultModel)")
            )
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

/// Editor for the editable part of the minutes prompt.
private struct MinutesInstructionsRows: View {
    let settings: SettingsStore

    var body: some View {
        PromptEditorRow(
            title: "議事録のプロンプト",
            text: settings.meetingMinutesInstructions ?? MeetingMinutesPrompt.defaultInstructions,
            limit: MeetingMinutesPrompt.instructionsLimit,
            defaultText: MeetingMinutesPrompt.defaultInstructions,
            explanation:
                "議事録に書く内容と書き方を指定します。1 行目のタイトル(ファイル名に使います)、辞書の扱い、出力の形式についての指示は自動で加わります。空欄のときはデフォルトのプロンプトを使います。",
            onSave: settings.setMeetingMinutesInstructions)
    }
}
