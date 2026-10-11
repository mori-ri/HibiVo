import SwiftUI

// Settings pages are built from these instead of a grouped `Form`: macOS draws grouped-form
// sections with a fixed translucent fill that cannot be restyled, which left text low-contrast
// on the glass backdrop.

/// Scrolling column of `SettingsSection`s.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
    }
}

/// Titled card of rows with an optional explanatory footer.
struct SettingsSection<Content: View>: View {
    var title: LocalizedStringKey? = nil
    var footer: LocalizedStringKey? = nil
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            // Every row draws a separator on its top edge; shifting up by its thickness tucks
            // the first one under the clip so only the separators between rows show.
            .padding(.top, -1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.cardStroke, lineWidth: 1))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// One row inside a `SettingsSection`.
struct SettingsRow<Content: View>: View {
    /// Where the separator starts; rows led by an icon start it past the icon.
    var separatorInset: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .overlay(alignment: .top) {
                Theme.separator.frame(height: 1).padding(.leading, separatorInset)
            }
    }
}

/// Label on the left, control on the right.
struct LabeledRow<Label: View, Control: View>: View {
    @ViewBuilder var label: Label
    @ViewBuilder var control: Control

    var body: some View {
        SettingsRow {
            HStack(spacing: 12) {
                label
                Spacer(minLength: 12)
                control
            }
        }
    }
}

extension LabeledRow where Label == Text {
    init(_ title: LocalizedStringKey, @ViewBuilder control: () -> Control) {
        self.init(Text(title), control: control)
    }

    init(_ title: Text, @ViewBuilder control: () -> Control) {
        self.init(label: { title }, control: control)
    }
}

struct ToggleRow: View {
    let title: Text
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = Text(title)
        self._isOn = isOn
    }

    var body: some View {
        LabeledRow(title) {
            Toggle(isOn: $isOn) { title }
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

struct PickerRow<Selection: Hashable, Options: View>: View {
    let title: Text
    @Binding var selection: Selection
    @ViewBuilder var options: Options

    init(_ title: LocalizedStringKey, selection: Binding<Selection>, @ViewBuilder options: () -> Options) {
        self.title = Text(title)
        self._selection = selection
        self.options = options()
    }

    var body: some View {
        LabeledRow(title) {
            Picker(selection: $selection) {
                options
            } label: {
                title
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

struct TextFieldRow: View {
    let title: Text
    @Binding var text: String
    var prompt: Text? = nil

    init(_ title: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey? = nil) {
        self.title = Text(title)
        self._text = text
        self.prompt = prompt.map { Text($0) }
    }

    /// For a prompt that is a value (a default model or region), not text to translate.
    init(_ title: LocalizedStringKey, text: Binding<String>, prompt verbatim: String) {
        self.init(title, text: text)
        self.prompt = Text(verbatim: verbatim)
    }

    var body: some View {
        LabeledRow(title) {
            TextField(text: $text, prompt: prompt) { title }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 340)
        }
    }
}

/// Small secondary text inside a card.
struct NoteRow: View {
    let text: Text
    var color: Color? = nil

    init(_ text: LocalizedStringKey, color: Color? = nil) {
        self.text = Text(text)
        self.color = color
    }

    /// For text that is already localized, such as an error message.
    @_disfavoredOverload
    init(_ text: String, color: Color? = nil) {
        self.text = Text(verbatim: text)
        self.color = color
    }

    var body: some View {
        SettingsRow {
            text
                .font(.caption)
                .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A long prompt: a one-line preview in the card, edited in a sheet so it doesn't take over the page.
struct PromptEditorRow: View {
    let title: LocalizedStringKey
    /// The saved text.
    let text: String
    let limit: Int
    /// Shown in the row when `text` is empty.
    var placeholder: LocalizedStringKey = "未設定"
    /// Offered as "デフォルトに戻す" in the sheet when set.
    var defaultText: String? = nil
    /// What the prompt is for, shown above the editor.
    var explanation: LocalizedStringKey? = nil
    let onSave: (String) -> Void
    @State private var isEditing = false

    var body: some View {
        LabeledRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                (preview.map { Text(verbatim: $0) } ?? Text(placeholder))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } control: {
            Button("編集…") { isEditing = true }
        }
        .sheet(isPresented: $isEditing) {
            PromptEditorSheet(
                title: title, initialText: text, limit: limit, defaultText: defaultText, explanation: explanation,
                onSave: onSave)
        }
    }

    private var preview: String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}

/// Edits a draft; nothing is stored until "保存".
struct PromptEditorSheet: View {
    let title: LocalizedStringKey
    let limit: Int
    let defaultText: String?
    let explanation: LocalizedStringKey?
    let onSave: (String) -> Void
    @State private var draft: String
    @Environment(\.dismiss) private var dismiss

    init(
        title: LocalizedStringKey, initialText: String, limit: Int, defaultText: String?,
        explanation: LocalizedStringKey?,
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.limit = limit
        self.defaultText = defaultText
        self.explanation = explanation
        self.onSave = onSave
        _draft = State(initialValue: initialText)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if let explanation {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextEditor(text: limited)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.cardFill, in: shape)
                .overlay(shape.strokeBorder(Theme.cardStroke))
            HStack {
                if let defaultText {
                    Button("デフォルトに戻す") { draft = defaultText }
                        .disabled(draft == defaultText)
                }
                Text("\(draft.count) / \(limit) 文字")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(draft.count >= limit ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 600, minHeight: 420, idealHeight: 480)
    }

    private var limited: Binding<String> {
        Binding(get: { draft }, set: { draft = String($0.prefix(limit)) })
    }
}
