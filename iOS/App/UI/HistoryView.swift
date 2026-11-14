import SwiftUI
import UIKit

/// Recent dictations, newest first. Tapping one copies it, for when the keyboard couldn't insert it.
struct HistoryView: View {
    let store: HistoryStore

    @State private var copied: HistoryRecord.ID?

    var body: some View {
        NavigationStack {
            List(store.records) { record in
                Button {
                    UIPasteboard.general.string = record.finalText
                    copied = record.id
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        if record.status == .failed {
                            Label(
                                record.errorMessage ?? String(localized: "文字起こしに失敗しました"),
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .symbolRenderingMode(.multicolor)
                        } else {
                            Text(verbatim: record.finalText)
                        }
                        HStack(spacing: 6) {
                            Text(record.timestamp, format: .dateTime.month().day().hour().minute())
                            if record.id == copied {
                                Label("コピーしました", systemImage: "checkmark")
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(record.status == .failed)
            }
            .overlay {
                if store.records.isEmpty {
                    ContentUnavailableView(
                        "履歴はまだありません", systemImage: "clock",
                        description: Text("音声入力した文章がここに並びます。タップするとコピーできます。"))
                }
            }
            .navigationTitle("履歴")
        }
    }
}
