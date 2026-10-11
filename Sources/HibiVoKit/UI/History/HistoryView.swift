import AppKit
import SwiftUI

/// A row in the history list: a dictation, or a meeting saved in the Meetings folder.
private enum HistoryItem: Identifiable {
    case dictation(HistoryRecord)
    case meeting(MeetingRecord)

    var id: String {
        switch self {
        case .dictation(let record): "dictation-\(record.id)"
        case .meeting(let record): "meeting-\(record.id)"
        }
    }

    var date: Date {
        switch self {
        case .dictation(let record): record.timestamp
        case .meeting(let record): record.startedAt
        }
    }
}

struct HistoryView: View {
    let env: AppEnvironment
    @State private var selection: String? = nil

    private var items: [HistoryItem] {
        (env.history.records.map(HistoryItem.dictation) + env.meetings.records.map(HistoryItem.meeting))
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        let items = items
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("履歴はまだありません", systemImage: "clock")
                } description: {
                    if env.settings.historyEnabled {
                        Text("\(env.settings.hotkey.displayName) を押して話し、もう一度押すと、ここに記録されます。")
                    } else {
                        Text("履歴の保存がオフになっています。右上のスイッチでオンにすると、入力したテキストがここに記録されます。")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if !env.settings.historyEnabled {
                        Label("履歴は保存されていません。新しい入力は記録されません。", systemImage: "pause.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                    }
                    HStack(spacing: 0) {
                        List(items, selection: $selection) { item in
                            switch item {
                            case .dictation(let record): HistoryRow(record: record)
                            case .meeting(let record):
                                MeetingRow(record: record, isRecording: isRecording(record))
                                    .contextMenu { MeetingActions(env: env, record: record) }
                            }
                        }
                        .scrollContentBackground(.hidden)
                        .frame(width: 280)
                        Theme.separator.frame(width: 1)
                        Group {
                            switch items.first(where: { $0.id == selection }) {
                            case .dictation(let record): HistoryDetail(env: env, record: record).id(record.id)
                            case .meeting(let record):
                                MeetingDetail(env: env, record: record, isRecording: isRecording(record))
                            case nil:
                                Text("項目を選択してください")
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .glassPanel(cornerRadius: 14)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                }
            }
        }
        // The folder changes outside the app too (and while a meeting records), so look again
        // whenever something may have been written.
        .onAppear { env.meetings.refresh() }
        .onChange(of: env.state.phase) { env.meetings.refresh() }
        .onChange(of: env.state.meetingMinutesInProgress) { env.meetings.refresh() }
        .onChange(of: env.state.meetingTranscriptionsInProgress) { env.meetings.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            env.meetings.refresh()
        }
    }

    private func isRecording(_ record: MeetingRecord) -> Bool {
        guard env.state.phase == .meeting, let startedAt = env.state.meetingStartedAt else { return false }
        return MeetingDocument.fileName(startedAt: startedAt) == "\(record.id).md"
    }
}

/// Shown in the page header next to the title.
struct HistoryHeaderActions: View {
    let history: HistoryStore
    @Bindable var settings: SettingsStore
    @State private var confirming = false

    var body: some View {
        Toggle("履歴を保存", isOn: $settings.historyEnabled)
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("オフにすると、新しい入力を履歴に残しません。これまでの履歴は消えません。")
        Button("すべて削除", role: .destructive) { confirming = true }
            .disabled(history.records.isEmpty)
            .confirmationDialog("履歴をすべて削除しますか？", isPresented: $confirming) {
                Button("すべて削除", role: .destructive) { history.removeAll() }
            } message: {
                Text("音声入力の履歴を削除します。この操作は取り消せません。ミーティングのファイルは削除しません。")
            }
    }
}

private struct HistoryRow: View {
    let record: HistoryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(
                verbatim: record.finalText.isEmpty
                    ? (record.errorMessage ?? String(localized: "（空）")) : record.finalText
            )
            .lineLimit(2)
            HStack(spacing: 6) {
                Text(record.timestamp, format: .dateTime.month().day().hour().minute())
                if let app = record.appName { Text(app) }
                StatusBadge(status: record.status)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct StatusBadge: View {
    let status: HistoryRecord.Status

    var body: some View {
        switch status {
        case .pasted: EmptyView()
        case .pastedRaw: Text("整形なし").foregroundStyle(.orange)
        case .copiedOnly: Text("コピーのみ").foregroundStyle(.orange)
        case .failed: Text("失敗").foregroundStyle(.red)
        }
    }
}

private struct HistoryDetail: View {
    let env: AppEnvironment
    let record: HistoryRecord
    @State private var isRetrying = false
    @State private var retryFailed = false
    /// The text being corrected; nil when not editing.
    @State private var draft: String?
    /// Words the last correction fixed, offered for the dictionary.
    @State private var suggestions: [VocabularyCorrection] = []
    @State private var learned: Set<VocabularyCorrection> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let draft {
                    editor(draft)
                } else {
                    section(record.correctedText == nil ? "入力されたテキスト" : "修正後のテキスト", text: record.finalText)
                }
                if !suggestions.isEmpty { suggestionList }
                if record.correctedText != nil {
                    section("入力されたテキスト", text: record.insertedText)
                }
                if record.cleanedTranscript != nil {
                    section("文字起こし（原文）", text: record.rawTranscript)
                }
                if let error = record.errorMessage, record.status == .failed {
                    Text(verbatim: error).foregroundStyle(.red)
                }

                HStack {
                    Button("コピー") { env.copy(record.finalText) }
                    Button("原文をコピー") { env.copy(record.rawTranscript) }
                        .disabled(record.cleanedTranscript == nil)
                    Button("もう一度入力") { env.pasteAgain(record.finalText) }
                    Button(isRetrying ? "整形中…" : "整形をやり直す") { retry() }
                        .disabled(isRetrying || record.rawTranscript.isEmpty)
                    Button("修正") { draft = record.finalText }
                        .disabled(draft != nil || record.finalText.isEmpty)
                }
                .disabled(record.finalText.isEmpty && record.rawTranscript.isEmpty)
                if retryFailed { Text("整形できませんでした。AI 整形の設定を確認してください。").font(.caption).foregroundStyle(.red) }

                Grid(alignment: .leading, verticalSpacing: 4) {
                    info("日時", record.timestamp.formatted(date: .abbreviated, time: .standard))
                    info("アプリ", record.appName ?? "—")
                    info("STT", record.provider)
                    info("モード", record.cleanupMode.displayName)
                    info("録音終了から入力まで", "\(record.latencyMs) ms")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(verbatim: text).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
        }
    }

    private func info(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label)
            Text(verbatim: value)
        }
    }

    private func editor(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("テキストを修正").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { draft ?? text }, set: { draft = $0 }))
                .font(.system(size: 14))
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.6)))
            HStack {
                Button("保存") { saveCorrection() }
                    .keyboardShortcut(.defaultAction)
                Button("キャンセル") { draft = nil }
                    .keyboardShortcut(.cancelAction)
            }
            Text("誤認識された言葉を直すと、辞書への追加を提案します。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("辞書に追加").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ForEach(suggestions, id: \.self) { correction in
                HStack(spacing: 8) {
                    Text("\(correction.original) → \(correction.corrected)")
                    if learned.contains(correction) {
                        Label("追加しました", systemImage: "checkmark").foregroundStyle(.secondary)
                    } else {
                        Button("追加") {
                            if env.vocabulary.learn(correction) != nil { learned.insert(correction) }
                        }
                        .disabled(!env.vocabulary.canLearn(correction))
                    }
                }
                .font(.system(size: 13))
            }
        }
    }

    private func saveCorrection() {
        guard let text = draft else { return }
        suggestions = env.saveCorrection(text, for: record)
        learned = []
        draft = nil
    }

    private func retry() {
        isRetrying = true
        retryFailed = false
        Task {
            retryFailed = !(await env.retryCleanup(record))
            isRetrying = false
        }
    }
}

// MARK: - Meetings

private struct MeetingRow: View {
    let record: MeetingRecord
    let isRecording: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.2.wave.2")
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                (record.title.map { Text(verbatim: $0) } ?? Text("ミーティング"))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(record.startedAt, format: .dateTime.month().day().hour().minute())
                    if isRecording {
                        Text("記録中").foregroundStyle(.red)
                    } else if record.minutesURL != nil {
                        Text("議事録あり")
                    } else if record.transcriptURL != nil {
                        Text("文字起こし")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Open buttons for a meeting's files, shared by the detail pane and the row's context menu.
private struct MeetingActions: View {
    let env: AppEnvironment
    let record: MeetingRecord

    var body: some View {
        if let minutes = record.minutesURL {
            Button("議事録を開く") { env.openMeetingFile(minutes) }
        }
        if let transcript = record.transcriptURL {
            Button("文字起こしを開く") { env.openMeetingFile(transcript) }
        }
        if let url = record.primaryURL {
            Button("Finder で表示") { env.revealMeetingFile(url) }
        }
    }
}

private struct MeetingDetail: View {
    let env: AppEnvironment
    let record: MeetingRecord
    let isRecording: Bool
    @State private var preview: String?

    /// Long meetings run to hundreds of kilobytes; the full text is one click away in the editor.
    private static let previewLimit = 20_000

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    (record.title.map { Text(verbatim: $0) } ?? Text("ミーティング"))
                        .font(.system(size: 17, weight: .semibold))
                    Text(verbatim: record.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack { MeetingActions(env: env, record: record) }

                if isRecording {
                    Text("記録中です。文字起こしは数秒ごとにファイルへ書き足されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let preview {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.minutesURL != nil ? "議事録" : "文字起こし")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(verbatim: preview).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Keyed on the files so a new version (minutes arriving, more transcript) is picked up.
        .task(id: record) { await loadPreview() }
    }

    private func loadPreview() async {
        guard let url = record.primaryURL else {
            preview = nil
            return
        }
        let limit = Self.previewLimit
        let more = String(localized: "…（続きはファイルを開いてください）")
        preview = await Task.detached {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return text.count > limit ? String(text.prefix(limit)) + "\n\n" + more : text
        }.value
    }
}
