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
    var title: String? = nil
    var footer: String? = nil
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
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .overlay(alignment: .top) {
                Theme.separator.frame(height: 1).padding(.leading, 14)
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
    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.init(label: { Text(title) }, control: control)
    }
}

struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        LabeledRow(title) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

struct PickerRow<Selection: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Selection
    @ViewBuilder var options: Options

    init(_ title: String, selection: Binding<Selection>, @ViewBuilder options: () -> Options) {
        self.title = title
        self._selection = selection
        self.options = options()
    }

    var body: some View {
        LabeledRow(title) {
            Picker(title, selection: $selection) { options }
                .labelsHidden()
                .fixedSize()
        }
    }
}

struct TextFieldRow: View {
    let title: String
    @Binding var text: String
    var prompt: String? = nil

    init(_ title: String, text: Binding<String>, prompt: String? = nil) {
        self.title = title
        self._text = text
        self.prompt = prompt
    }

    var body: some View {
        LabeledRow(title) {
            TextField(title, text: $text, prompt: prompt.map { Text($0) })
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 340)
        }
    }
}

/// Small secondary text inside a card.
struct NoteRow: View {
    let text: String
    var color: Color? = nil

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        SettingsRow {
            Text(text)
                .font(.caption)
                .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
