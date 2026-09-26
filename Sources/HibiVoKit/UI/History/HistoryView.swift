import SwiftUI

public struct HistoryView: View {
    let env: AppEnvironment
    @State private var selection: HistoryRecord.ID? = nil

    public init(env: AppEnvironment) {
        self.env = env
    }

    public var body: some View {
        NavigationSplitView {
            List(env.history.records, selection: $selection) { record in
                HistoryRow(record: record)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .overlay {
                if env.history.records.isEmpty {
                    ContentUnavailableView("履歴はまだありません", systemImage: "clock")
                }
            }
        } detail: {
            if let record = env.history.records.first(where: { $0.id == selection }) {
                HistoryDetail(env: env, record: record)
            } else {
                Text("項目を選択してください").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 680, minHeight: 420)
        .toolbar {
            Button("すべて削除", role: .destructive) { env.history.removeAll() }
                .disabled(env.history.records.isEmpty)
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
        .padding(.vertical, 2)
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
            VStack(alignment: .leading, spacing: 16) {
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
                    info("キーを離してから入力まで", "\(record.latencyMs) ms")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).textSelection(.enabled)
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
