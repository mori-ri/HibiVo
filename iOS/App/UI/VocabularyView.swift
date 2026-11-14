import SwiftUI

/// The user dictionary: spellings to prefer, and what they tend to be misheard as.
struct VocabularyView: View {
    let store: VocabularyStore

    @State private var editing: VocabularyEntry?
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.entries) { entry in
                    Button {
                        editing = entry
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: entry.preferred)
                                .foregroundStyle(entry.isEnabled ? .primary : .secondary)
                            if !entry.spokenForms.isEmpty {
                                Text(verbatim: entry.spokenForms.joined(separator: "、"))  // no-l10n
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    store.remove(ids: Set(offsets.map { store.entries[$0].id }))
                }
            }
            .overlay {
                if store.entries.isEmpty {
                    ContentUnavailableView(
                        "辞書は空です", systemImage: "character.book.closed",
                        description: Text("社名や専門用語など、正しく書いてほしい言葉を登録すると、文字起こしと AI 整形がその表記を使います。"))
                }
            }
            .navigationTitle("辞書")
            .toolbar {
                Button("言葉を追加", systemImage: "plus") { isAdding = true }
            }
            .sheet(isPresented: $isAdding) {
                VocabularyEditor(entry: VocabularyEntry(preferred: "")) { store.add($0) }
            }
            .sheet(item: $editing) { entry in
                VocabularyEditor(entry: entry) { store.update($0) }
            }
        }
    }
}

private struct VocabularyEditor: View {
    @State var entry: VocabularyEntry
    var save: (VocabularyEntry) -> Void

    @State private var aliases = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("表記（例: AppSync）", text: $entry.preferred)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("入力してほしい書き方です。")
                }
                Section {
                    TextField("読み（例: アップシンク）", text: $entry.spoken)
                    TextField("ほかの聞き取られ方（「、」で区切る）", text: $aliases)
                } footer: {
                    Text("こう聞き取られたときに、上の表記に置き換えます。空欄でもかまいません。")
                }
                Section {
                    Toggle("この言葉を使う", isOn: $entry.isEnabled)
                }
            }
            .navigationTitle(entry.preferred.isEmpty ? Text("言葉を追加") : Text(verbatim: entry.preferred))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var entry = entry
                        entry.preferred = entry.preferred.trimmingCharacters(in: .whitespaces)
                        entry.aliases = Self.split(aliases)
                        save(entry)
                        dismiss()
                    }
                    .disabled(entry.preferred.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { aliases = entry.aliases.joined(separator: "、") }  // no-l10n
        }
    }

    /// Splits on the Japanese and the ASCII comma, whichever the user typed.
    static func split(_ aliases: String) -> [String] {
        aliases.split(whereSeparator: { $0 == "、" || $0 == "," })  // no-l10n
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
