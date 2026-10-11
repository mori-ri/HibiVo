import AppKit
import SwiftUI

/// A small floating window for notes during a meeting. It opens when a meeting starts and closes when
/// it ends; the HUD's notes button reopens it.
///
/// It is a non-activating panel, so it shows up without taking focus from the meeting app and can be
/// typed in without bringing HibiVo to the front. It becomes key only when the text is clicked.
@MainActor
public final class MeetingNotesPanelController {
    private let state: AppState
    private var panel: NSPanel?
    private var wasMeeting = false

    public init(state: AppState) {
        self.state = state
        observe()
    }

    public var isVisible: Bool { panel?.isVisible == true }

    public func toggle() {
        if isVisible { panel?.orderOut(nil) } else { show() }
    }

    public func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    private func observe() {
        let isMeeting = state.phase == .meeting
        if isMeeting, !wasMeeting {
            show()
        } else if !isMeeting, wasMeeting {
            panel?.orderOut(nil)
        }
        wasMeeting = isMeeting
        withObservationTracking {
            _ = state.phase
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.title = String(localized: "ミーティングのメモ")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 280, height: 180)
        panel.contentView = FirstMouseHostingView(rootView: MeetingNotesView(state: state))
        // Top right of the screen, out of the way of the HUD at the bottom; then wherever the user left it.
        if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - panel.frame.width - 24, y: visible.maxY - 24))
        }
        panel.setFrameAutosaveName("MeetingNotes")
        return panel
    }
}

/// The panel is usually not key (the meeting app is in front), so the toolbar must act on the first click.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct MeetingNotesView: View {
    @Bindable var state: AppState
    @State private var editor = MarkdownEditorProxy()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                button(.heading, "textformat.size", "見出し")
                button(.bold, "bold", "太字")
                button(.bulletList, "list.bullet", "箇条書き")
                button(.numberedList, "list.number", "番号付きリスト")
                button(.checklist, "checklist", "チェックリスト")
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            Divider()
            MarkdownTextEditor(text: $state.meetingNotes, proxy: editor)
            Divider()
            Text("メモは文字起こしの先頭に入り、議事録を作るときに参考にされます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
    }

    private func button(_ style: MarkdownStyle, _ symbol: String, _ label: LocalizedStringKey) -> some View {
        Button {
            editor.apply(style)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Lets the toolbar reach the text view to format the selection.
@MainActor
final class MarkdownEditorProxy {
    weak var textView: NSTextView?

    func apply(_ style: MarkdownStyle) {
        guard let textView else { return }
        // The toolbar doesn't take focus; give it back to the text so typing continues there.
        textView.window?.makeKey()
        textView.window?.makeFirstResponder(textView)
        Self.perform(
            MarkdownEditing.apply(style, to: textView.string, selection: textView.selectedRange()), in: textView)
    }

    /// Through `insertText` so the change is undoable and reported to the delegate like typing.
    static func perform(_ edit: MarkdownEdit, in textView: NSTextView) {
        textView.insertText(edit.replacement, replacementRange: edit.range)
        textView.setSelectedRange(edit.selection)
        textView.scrollRangeToVisible(edit.selection)
    }
}

/// A plain-text editor for Markdown: no rich text and no smart quotes or dashes, which would break
/// the syntax. Return continues a list; Tab and Shift-Tab indent and outdent lines.
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    let proxy: MarkdownEditorProxy

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        let textView = scrollView.documentView as! NSTextView
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.string = text
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel(String(localized: "ミーティングのメモ"))
        proxy.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        if textView.hasMarkedText() {
            // Leave a composition alone, except when the meeting ends and the notes are cleared:
            // otherwise the old text would stay in the view and be carried into the next meeting.
            guard text.isEmpty else { return }
            textView.inputContext?.discardMarkedText()
            textView.unmarkText()
        }
        textView.string = text
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            let text = textView.string
            let selection = textView.selectedRange()
            let edit: MarkdownEdit?
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                edit = MarkdownEditing.lineBreak(in: text, selection: selection)
            case #selector(NSResponder.insertTab(_:)):
                edit = MarkdownEditing.indent(in: text, selection: selection, outdent: false)
            case #selector(NSResponder.insertBacktab(_:)):
                edit = MarkdownEditing.indent(in: text, selection: selection, outdent: true)
            default:
                edit = nil
            }
            guard let edit else { return false }
            MarkdownEditorProxy.perform(edit, in: textView)
            return true
        }
    }
}
