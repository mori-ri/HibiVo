import SwiftUI

struct HistoryView: View {
    let env: AppEnvironment
    @State private var selection: HistoryRecord.ID? = nil

    var body: some View {
        if env.history.records.isEmpty {
            ContentUnavailableView {
                Label("履歴はまだありません", systemImage: "clock")
            } description: {
                Text("\(env.settings.hotkey.displayName) を押して話し、もう一度押すと、ここに記録されます。")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                List(env.history.records, selection: $selection) { record in
                    HistoryRow(record: record)
                }
                .scrollContentBackground(.hidden)
                .frame(width: 280)
                Theme.separator.frame(width: 1)
                Group {
                    if let record = env.history.records.first(where: { $0.id == selection }) {
                        HistoryDetail(env: env, record: record)
                    } else {
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

/// Shown in the page header next to the title.
struct HistoryHeaderActions: View {
    let history: HistoryStore
    @State private var confirming = false

    var body: some View {
        Button("すべて削除", role: .destructive) { confirming = true }
            .disabled(history.records.isEmpty)
            .confirmationDialog("履歴をすべて削除しますか？", isPresented: $confirming) {
                Button("すべて削除", role: .destructive) { history.removeAll() }
            } message: {
                Text("この操作は取り消せません。")
            }
    }
}

private struct HistoryRow: View {
    let record: HistoryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.finalText.isEmpty ? (record.errorMessage ?? "（空）") : record.finalText)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("入力されたテキスト", text: record.finalText)
                if record.cleanedTranscript != nil {
                    section("文字起こし（原文）", text: record.rawTranscript)
                }
                if let error = record.errorMessage, record.status == .failed {
                    Text(error).foregroundStyle(.red)
                }

                HStack {
                    Button("コピー") { env.copy(record.finalText) }
                    Button("原文をコピー") { env.copy(record.rawTranscript) }
                        .disabled(record.cleanedTranscript == nil)
                    Button("もう一度入力") { env.pasteAgain(record.finalText) }
                    Button(isRetrying ? "整形中…" : "整形をやり直す") { retry() }
                        .disabled(isRetrying || record.rawTranscript.isEmpty)
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

    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
            Text(value)
        }
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
