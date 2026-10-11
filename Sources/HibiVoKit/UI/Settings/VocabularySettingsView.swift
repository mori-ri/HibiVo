import SwiftUI

struct VocabularySettingsView: View {
    let store: VocabularyStore
    @Bindable var settings: SettingsStore
    @State private var filter = Filter.all
    @State private var query = ""
    @State private var editing: VocabularyEntry.ID?

    var body: some View {
        SettingsPage {
            SettingsSection(
                title: "言葉を追加",
                footer: "正しい表記と、誤認識されやすい読み方を登録します。STT のヒントと AI 整形の両方に使われます。よく使う言葉と同じ読みを登録すると、ほかの言葉まで置き換わることがあります。"
            ) {
                VocabularyComposer(store: store)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(Filter.allCases) { option in
                        FilterChip(
                            title: option.title, count: store.entries.filter(option.includes).count,
                            isSelected: filter == option
                        ) { filter = option }
                    }
                    Spacer(minLength: 12)
                    SearchField(text: $query)
                }
                entryList
            }

            SettingsSection(
                title: "自動で追加",
                footer:
                    "入力した直後に、誤認識された言葉を書き直すと、その言葉を辞書に追加します。追加したときは画面下に表示され、クリックで取り消せます。入力欄の内容はアクセシビリティ機能で読み取り、保存も送信もしません。内容を読み取れないアプリ（ターミナルなど）では、履歴の「修正」から追加できます。"
            ) {
                ToggleRow("入力後に直した言葉を辞書に追加する", isOn: $settings.learnsFromCorrections)
            }
        }
    }

    @ViewBuilder
    private var entryList: some View {
        let entries = visibleEntries
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: query.isEmpty ? "character.book.closed" : "magnifyingglass")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(query.isEmpty ? filter.emptyText : "「\(query)」に一致する言葉はありません")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                ForEach(entries) { entry in
                    VocabularyRow(
                        entry: entry, store: store, isEditing: editing == entry.id,
                        isFirst: entry.id == entries.first?.id
                    ) {
                        withAnimation(.snappy(duration: 0.22)) {
                            editing = editing == entry.id ? nil : entry.id
                        }
                    }
                }
            }
        }
        .background(Theme.cardFill)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.cardStroke, lineWidth: 1))
    }

    /// Newest first, so a word just learned or added is at the top.
    private var visibleEntries: [VocabularyEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return store.entries.reversed().filter { entry in
            filter.includes(entry)
                && (needle.isEmpty
                    || ([entry.preferred] + entry.spokenForms).contains { $0.localizedStandardContains(needle) })
        }
    }

    static var contextualNote: String {
        String(
            localized:
                "2 文字以下のひらがな・カタカナの読みは、ほかの言葉と取り違えやすいため自動では置き換えません。AI 整形で文脈に合うと判断されたときだけ、この表記にします。"
        )
    }

    static func splitAliases(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "、" })  // no-l10n
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

extension VocabularySettingsView {
    enum Filter: CaseIterable, Identifiable {
        case all, manual, learned, disabled

        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .all: "すべて"
            case .manual: "手動"
            case .learned: "自動"
            case .disabled: "無効"
            }
        }

        var emptyText: LocalizedStringKey {
            switch self {
            case .all: "まだ登録されていません"
            case .manual: "手動で追加した言葉はありません"
            case .learned: "自動で追加された言葉はありません"
            case .disabled: "無効にした言葉はありません"
            }
        }

        func includes(_ entry: VocabularyEntry) -> Bool {
            switch self {
            case .all: true
            case .manual: entry.origin == .manual
            case .learned: entry.origin == .learned
            case .disabled: !entry.isEnabled
            }
        }
    }
}

// MARK: - Adding

private struct VocabularyComposer: View {
    let store: VocabularyStore
    @State private var preferred = ""
    @State private var spoken = ""
    @State private var aliases = ""
    @FocusState private var focusesPreferred: Bool

    var body: some View {
        SettingsRow {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    VocabularyField(title: "正しい表記", prompt: "AppSync", text: $preferred)
                        .focused($focusesPreferred)
                    VocabularyField(title: "読み", prompt: "アップシンク", text: $spoken)
                    VocabularyField(title: "別名（, 区切り）", prompt: "アップ シンク", text: $aliases)
                    Button(action: add) {
                        Label("追加", systemImage: "plus")
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(draft.preferred.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
                if !draft.contextualForms.isEmpty {
                    Label(VocabularySettingsView.contextualNote, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var draft: VocabularyEntry {
        VocabularyEntry(
            preferred: preferred.trimmingCharacters(in: .whitespaces),
            spoken: spoken.trimmingCharacters(in: .whitespaces),
            aliases: VocabularySettingsView.splitAliases(aliases))
    }

    private func add() {
        guard !draft.preferred.isEmpty else { return }
        store.add(draft)
        preferred = ""
        spoken = ""
        aliases = ""
        focusesPreferred = true
    }
}

// MARK: - List

private struct VocabularyRow: View {
    let entry: VocabularyEntry
    let store: VocabularyStore
    let isEditing: Bool
    let isFirst: Bool
    let toggleEditing: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                OriginIcon(origin: entry.origin)
                HStack(spacing: 6) {
                    (entry.preferred.isEmpty ? Text("（表記なし）") : Text(verbatim: entry.preferred))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(entry.preferred.isEmpty ? .tertiary : .primary)
                        .layoutPriority(1)
                    if !entry.contextualForms.isEmpty {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .help(VocabularySettingsView.contextualNote)
                    }
                    ForEach(entry.spokenForms, id: \.self) { FormChip(text: $0) }
                }
                .lineLimit(1)
                .opacity(entry.isEnabled ? 1 : 0.45)
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    RowIconButton(symbol: isEditing ? "checkmark" : "pencil", help: isEditing ? "完了" : "編集") {
                        toggleEditing()
                    }
                    .accessibilityLabel(
                        isEditing ? Text("\(entry.preferred) の編集を完了") : Text("\(entry.preferred) を編集"))
                    RowIconButton(symbol: "trash", help: "辞書から削除", role: .destructive) {
                        withAnimation(.snappy(duration: 0.2)) { store.remove(ids: [entry.id]) }
                    }
                    .accessibilityLabel("\(entry.preferred) を削除")
                }
                .opacity(isHovered || isEditing ? 1 : 0)
                Toggle("有効", isOn: binding(\.isEnabled))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(entry.isEnabled ? Text("オフにすると、削除せずに使わないようにできます") : Text("無効（使われません）"))
                    .accessibilityLabel("\(entry.preferred) を使う")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: toggleEditing)

            if isEditing {
                HStack(alignment: .bottom, spacing: 8) {
                    VocabularyField(title: "正しい表記", prompt: "AppSync", text: binding(\.preferred))
                    VocabularyField(title: "読み", prompt: "アップシンク", text: binding(\.spoken))
                    VocabularyField(title: "別名（, 区切り）", prompt: "", text: aliasBinding)
                }
                .padding(.leading, 44)
                .padding(.trailing, 14)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(isHovered && !isEditing ? Theme.hover : .clear)
        .background(isEditing ? Color.accentColor.opacity(0.06) : .clear)
        .overlay(alignment: .top) {
            if !isFirst { Theme.separator.frame(height: 1).padding(.leading, 44) }
        }
        .onHover { isHovered = $0 }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<VocabularyEntry, Value>) -> Binding<Value> {
        Binding(
            get: { entry[keyPath: keyPath] },
            set: { newValue in
                var updated = entry
                updated[keyPath: keyPath] = newValue
                store.update(updated)
            })
    }

    private var aliasBinding: Binding<String> {
        Binding(
            get: { entry.aliases.joined(separator: ", ") },
            set: { newValue in
                var updated = entry
                updated.aliases = VocabularySettingsView.splitAliases(newValue)
                store.update(updated)
            })
    }
}

/// Leading tile: a text cursor for words the user typed, the logo gradient with sparkles for learned ones.
struct OriginIcon: View {
    let origin: VocabularyEntry.Origin

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Group {
            switch origin {
            case .manual:
                Image(systemName: "character.cursor.ibeam")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(shape.fill(.primary.opacity(0.06)))
            case .learned:
                Image(systemName: "sparkles")
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(shape.fill(Theme.brandGradient))
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .help(origin == .manual ? Text("手動で追加した言葉") : Text("入力後の修正から自動で追加された言葉"))
    }
}

/// One spoken form, after the spelling.
private struct FormChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.primary.opacity(0.05)))
    }
}

private struct RowIconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    var role: ButtonRole? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered && role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 22)
                .background {
                    if isHovered { Circle().fill(.primary.opacity(0.07)) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

// MARK: - Controls

/// Caption over a soft, borderless text field.
private struct VocabularyField: View {
    let title: LocalizedStringKey
    let prompt: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(title, text: $text, prompt: Text(""))
                .labelsHidden()
                .textFieldStyle(.plain)
                .background(alignment: .leading) { Placeholder(text: prompt, isVisible: text.isEmpty) }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.cardStroke))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FilterChip: View {
    let title: LocalizedStringKey
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                Text(verbatim: "\(count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background {
                let shape = Capsule()
                if isSelected {
                    shape.fill(Theme.selection)
                        .overlay(shape.strokeBorder(Theme.rim, lineWidth: 0.5))
                        .shadow(color: Theme.selectionShadow, radius: 3, y: 1)
                } else if isHovered {
                    shape.fill(Theme.hover)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("検索", text: $text, prompt: Text(""))
                .labelsHidden()
                .textFieldStyle(.plain)
                .background(alignment: .leading) { Placeholder(text: "言葉を検索", isVisible: text.isEmpty) }
                .font(.system(size: 12))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("検索をクリア")
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 180, height: 26)
        .background(Capsule().fill(Theme.cardFill))
        .overlay(Capsule().strokeBorder(Theme.cardStroke))
    }
}

/// Drawn by SwiftUI: a plain field's own placeholder ignores `foregroundStyle` and reads like typed text.
private struct Placeholder: View {
    let text: LocalizedStringKey
    let isVisible: Bool

    var body: some View {
        Text(text)
            .foregroundStyle(.tertiary)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
