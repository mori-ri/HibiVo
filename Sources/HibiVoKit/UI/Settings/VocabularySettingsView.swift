import SwiftUI

struct VocabularySettingsView: View {
    let store: VocabularyStore
    @State private var selection = Set<VocabularyEntry.ID>()
    @State private var preferred = ""
    @State private var spoken = ""
    @State private var aliases = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "正しい表記と、誤認識されやすい読み方を登録します。STT のヒントと AI 整形の両方に使われます。"
                    + "よく使う言葉と同じ読みを登録すると、ほかの言葉まで置き換わることがあります。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Table(store.entries, selection: $selection) {
                TableColumn("正しい表記") { entry in
                    TextField("AppSync", text: binding(entry, \.preferred))
                }
                TableColumn("読み（任意）") { entry in
                    HStack(spacing: 4) {
                        TextField("アップシンク", text: binding(entry, \.spoken))
                        if !entry.contextualForms.isEmpty {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                                .help(Self.contextualNote)
                        }
                    }
                }
                TableColumn("別名（, 区切り）") { entry in
                    TextField("", text: aliasBinding(entry))
                }
            }
            .alternatingRowBackgrounds(.disabled)
            .scrollContentBackground(.hidden)
            .overlay {
                if store.entries.isEmpty {
                    Text("まだ登録されていません").foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .glassPanel(cornerRadius: 14)

            HStack {
                TextField("正しい表記", text: $preferred)
                TextField("読み", text: $spoken)
                TextField("別名（, 区切り）", text: $aliases)
                Button("追加", action: add)
                    .disabled(preferred.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("削除") { store.remove(ids: selection) }
                    .disabled(selection.isEmpty)
            }
            .textFieldStyle(.roundedBorder)

            if !draft.contextualForms.isEmpty {
                Label(Self.contextualNote, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    static let contextualNote =
        "2 文字以下のひらがな・カタカナの読みは、ほかの言葉と取り違えやすいため自動では置き換えません。"
        + "AI 整形で文脈に合うと判断されたときだけ、この表記にします。"

    private var draft: VocabularyEntry {
        VocabularyEntry(
            preferred: preferred.trimmingCharacters(in: .whitespaces),
            spoken: spoken.trimmingCharacters(in: .whitespaces),
            aliases: Self.splitAliases(aliases))
    }

    private func add() {
        store.add(draft)
        preferred = ""
        spoken = ""
        aliases = ""
    }

    private func binding(
        _ entry: VocabularyEntry, _ keyPath: WritableKeyPath<VocabularyEntry, String>
    ) -> Binding<String> {
        Binding(
            get: { entry[keyPath: keyPath] },
            set: { newValue in
                var updated = entry
                updated[keyPath: keyPath] = newValue
                store.update(updated)
            })
    }

    private func aliasBinding(_ entry: VocabularyEntry) -> Binding<String> {
        Binding(
            get: { entry.aliases.joined(separator: ", ") },
            set: { newValue in
                var updated = entry
                updated.aliases = Self.splitAliases(newValue)
                store.update(updated)
            })
    }

    static func splitAliases(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
