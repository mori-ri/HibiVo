import SwiftUI

/// Overview page: the last week's usage, how to use the hotkey, the models in use, the words the dictionary learned
/// lately, and feedback links.
struct HomeView: View {
    let env: AppEnvironment

    var body: some View {
        SettingsPage {
            usage
            HStack(alignment: .top, spacing: 16) {
                howTo.frame(maxWidth: .infinity)
                learnedWords.frame(maxWidth: .infinity)
            }
            models
            feedback
        }
    }

    // MARK: - Usage

    private var usage: some View {
        let series = env.usage.series(days: UsagePeriod.week.rawValue)
        let days = series.map(\.usage)
        let rate = env.settings.usdJPYRate
        return VStack(alignment: .leading, spacing: 8) {
            HomeSectionHeader(title: "直近 7 日の利用状況") {
                Button("詳しく見る") { show(.usage) }
            }
            StatTiles(
                days: days, estimate: UsagePricing.estimate(days), yenPerUSD: rate, showsCharacters: false)
            SettingsSection {
                SettingsRow {
                    DailyChart(series: series, metric: .dictations, period: .week, yenPerUSD: rate)
                        .frame(height: 140)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    // MARK: - Models

    /// What each step currently uses, resolved the same way a dictation or meeting would at start.
    private var models: some View {
        let settings = env.settings
        return VStack(alignment: .leading, spacing: 8) {
            HomeSectionHeader(title: "使用中のモデル") { EmptyView() }
            SettingsSection {
                ModelRow("音声入力の文字起こし", model: dictationModel) { show(.transcription) }
                ModelRow("AI 整形", model: cleanupModel) { show(.cleanup) }
                ModelRow("ミーティングの文字起こし", model: meetingModel) { show(.meeting) }
                ModelRow("議事録", model: minutesModel) { show(.meeting) }
            }
        }
    }

    private var minutesModel: (provider: String, model: String)? {
        let settings = env.settings
        guard settings.meetingMinutesEnabled else { return nil }
        switch settings.meetingMinutesEngine {
        case .claudeCode:
            return ("Claude Code", settings.meetingMinutesModel.rawValue.capitalized)
        case .bedrock:
            guard BedrockCleanupProvider.configured(settings: settings, secrets: env.secrets) != nil else {
                return ("Amazon Bedrock", Self.missingKey)
            }
            return ("Amazon Bedrock", settings.resolvedMeetingMinutesModel)
        }
    }

    private var dictationModel: (provider: String, model: String)? {
        let providers = env.transcriptionProviders
        guard
            let provider = providers.first(where: { $0.id == env.settings.transcriptionProviderID })
                ?? providers.first
        else { return nil }
        guard hasKey(for: provider) else { return (provider.displayName, Self.missingKey) }
        return (provider.displayName, Self.model(env.settings.transcriptionModel, of: provider))
    }

    private var cleanupModel: (provider: String, model: String)? {
        let settings = env.settings
        guard settings.cleanupEnabled else { return nil }
        let kind = CleanupProviderKind(rawValue: settings.cleanupProviderID) ?? .anthropic
        // Without credentials every dictation is pasted raw, so don't present the model as in use.
        guard env.hasCleanupCredentials else { return (kind.displayName, Self.missingKey) }
        let model = settings.cleanupModel.isEmpty ? kind.defaultModel : settings.cleanupModel
        return (kind.displayName, model.isEmpty ? "モデル未設定" : model)
    }

    private var meetingModel: (provider: String, model: String)? {
        let settings = env.settings
        let transcribers = env.meetingTranscribers
        guard
            let stt = transcribers.first(where: { $0.provider.id == settings.meetingTranscriptionProviderID })
                ?? transcribers.first
        else { return nil }
        guard hasKey(for: stt.provider) else { return (stt.provider.displayName, Self.missingKey) }
        if settings.meetingTranscriptionTiming == .afterMeeting, let file = stt.fileTranscriber {
            return (stt.provider.displayName, file.model)
        }
        return (stt.provider.displayName, Self.model(settings.transcriptionModel, of: stt.provider))
    }

    private static let missingKey = "API キー未設定"

    private func hasKey(for provider: any TranscriptionProvider) -> Bool {
        !provider.requiresAPIKey || env.secrets.secret(for: provider.id)?.isEmpty == false
    }

    /// A model saved for another provider falls back to this one's default, as `DictationContextBuilder` does.
    /// macOS's recognizer has no model name worth showing, so it says where the audio is processed instead.
    private static func model(_ saved: String, of provider: any TranscriptionProvider) -> String {
        if provider is AppleSpeechProvider { return "端末内" }
        return provider.models.contains(saved) ? saved : provider.defaultModel
    }

    // MARK: - How to

    private var howTo: some View {
        let key = env.settings.hotkey.displayName
        return VStack(alignment: .leading, spacing: 8) {
            HomeSectionHeader(title: "使い方") {
                Button("ホットキーを変更") { show(.general) }
            }
            SettingsSection {
                ShortcutRow("話す・入力する", keys: [key])
                ShortcutRow("押している間だけ話す", keys: ["\(key) 長押し"])
                ShortcutRow("録音をやめる", keys: ["esc"])
                ShortcutRow("ミーティングを記録", keys: [key, "M"])
                ShortcutRow("ミーティングを終了", keys: ["\(key) 2 回"])
            }
        }
    }

    // MARK: - Learned words

    private static let learnedLimit = 4

    /// The newest words learned from corrections, so the user sees the dictionary getting better.
    private var learnedWords: some View {
        let learned = env.vocabulary.entries.filter { $0.origin == .learned && $0.isEnabled }
        return VStack(alignment: .leading, spacing: 8) {
            HomeSectionHeader(title: "最近覚えた言葉") {
                Button("辞書を開く") { show(.vocabulary) }
            }
            SettingsSection {
                if learned.isEmpty {
                    NoteRow(
                        env.settings.learnsFromCorrections
                            ? "入力したあとに誤認識を直すと、その言葉を覚えてここに表示します。"
                            : "直した言葉を覚える機能はオフです。辞書のページでオンにできます。")
                } else {
                    // `learn` appends, so the newest are at the end.
                    ForEach(learned.suffix(Self.learnedLimit).reversed()) { LearnedWordRow(entry: $0) }
                    if learned.count > Self.learnedLimit {
                        NoteRow("ほかに \(learned.count - Self.learnedLimit) 語を覚えています。")
                    }
                }
            }
        }
    }

    // MARK: - Feedback

    private var feedback: some View {
        SettingsSection(
            title: "フィードバック",
            footer: "使いにくいところ、欲しい機能、質問など、小さなことでも気軽に送ってください。ブラウザで GitHub Discussions が開きます。"
        ) {
            LabeledRow("感想・要望を送る") {
                Button("開く…") { ProjectLinks.open(ProjectLinks.newFeedback) }
            }
            LabeledRow("みんなの投稿を見る") {
                Button("開く…") { ProjectLinks.open(ProjectLinks.discussions) }
            }
            LabeledRow("GitHub リポジトリ") {
                Button("開く…") { ProjectLinks.open(ProjectLinks.repository) }
            }
        }
    }

    // MARK: - Navigation

    private func show(_ section: MainSection) {
        env.state.mainSection = section
    }
}

// MARK: - Components

/// Section title with a link-style action on the right.
private struct HomeSectionHeader<Action: View>: View {
    let title: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            action
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 4)
    }
}

/// The step on the left, the service and model it uses on the right ("オフ" when the step is off),
/// and a button to the page where it is set.
private struct ModelRow: View {
    let title: String
    let model: (provider: String, model: String)?
    let change: () -> Void

    init(_ title: String, model: (provider: String, model: String)?, change: @escaping () -> Void) {
        self.title = title
        self.model = model
        self.change = change
    }

    var body: some View {
        LabeledRow(title) {
            if let model {
                HStack(spacing: 6) {
                    Text(model.provider).foregroundStyle(.secondary)
                    Text(model.model)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
                .lineLimit(1)
                .truncationMode(.middle)
            } else {
                Text("オフ").foregroundStyle(.secondary)
            }
            Button("変更", action: change)
        }
    }
}

/// What the user does on the left, the keys on the right.
private struct ShortcutRow: View {
    let title: String
    let keys: [String]

    init(_ title: String, keys: [String]) {
        self.title = title
        self.keys = keys
    }

    var body: some View {
        LabeledRow(title) {
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    if index > 0 { Text("+").foregroundStyle(.tertiary) }
                    KeyCap(key)
                }
            }
        }
    }
}

private struct KeyCap: View {
    let key: String

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Text(key)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.selection, in: shape)
            .overlay(shape.strokeBorder(Theme.cardStroke, lineWidth: 1))
    }
}

/// "how STT heard it → how it is written now".
private struct LearnedWordRow: View {
    let entry: VocabularyEntry

    var body: some View {
        SettingsRow {
            HStack(spacing: 8) {
                OriginIcon(origin: .learned)
                if let heard = entry.spokenForms.first {
                    Text(heard)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(entry.preferred)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
    }
}
