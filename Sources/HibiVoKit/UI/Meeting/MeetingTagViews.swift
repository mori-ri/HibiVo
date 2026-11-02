import SwiftUI

/// The running meeting's title and tags, above the notes. A tag is added with Return, a comma or a
/// space, or by clicking one used in an earlier meeting; Delete in the empty field removes the last one.
struct MeetingDetailsFields: View {
    @Bindable var state: AppState
    /// Tags of earlier meetings, most recent first, leaving out the given ones.
    let recentTags: @MainActor ([String]) -> [String]
    @State private var tagInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("タイトル", text: $state.meetingTitle, prompt: Text(""))
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .background(alignment: .leading) {
                    FieldPlaceholder(text: "タイトル(省略可)", isVisible: state.meetingTitle.isEmpty)
                }
                .accessibilityLabel("ミーティングのタイトル")

            FlowLayout {
                Image(systemName: "tag")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(height: 20)
                    .accessibilityHidden(true)
                ForEach(state.meetingTags, id: \.self) { tag in
                    MeetingTagChip(tag: tag) { state.meetingTags.removeAll { $0 == tag } }
                }
                TextField("タグ", text: $tagInput, prompt: Text(""))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 120, height: 20)
                    .background(alignment: .leading) {
                        FieldPlaceholder(text: "タグを追加", isVisible: tagInput.isEmpty)
                    }
                    .accessibilityLabel("タグを追加")
                    .onSubmit { commitTags(isFinished: true) }
                    .onChange(of: tagInput) { commitTags(isFinished: false) }
                    .onKeyPress(.delete) {
                        guard tagInput.isEmpty, !state.meetingTags.isEmpty else { return .ignored }
                        state.meetingTags.removeLast()
                        return .handled
                    }
            }

            let suggestions = recentTags(state.meetingTags)
            if !suggestions.isEmpty {
                FlowLayout {
                    Text("最近のタグ")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(height: 20)
                    ForEach(suggestions, id: \.self) { tag in
                        SuggestedTagButton(tag: tag) { add([tag]) }
                    }
                }
            }
        }
    }

    private func commitTags(isFinished: Bool) {
        let (tags, remainder) = MeetingMetadata.splitTagInput(tagInput, isFinished: isFinished)
        guard !tags.isEmpty || remainder != tagInput else { return }
        add(tags)
        tagInput = remainder
    }

    private func add(_ tags: [String]) {
        var all = state.meetingTags
        for tag in tags { all = MeetingMetadata.adding(tag, to: all) }
        if all != state.meetingTags { state.meetingTags = all }
    }
}

/// A tag as a small chip; with `onRemove`, it carries a button that removes it.
struct MeetingTagChip: View {
    let tag: String
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 3) {
            Text(verbatim: "#\(tag)")
                .lineLimit(1)
                .truncationMode(.middle)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("タグを外す")
                .accessibilityLabel(Text("\(tag) を外す"))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.primary.opacity(0.06)))
    }
}

/// A tag from an earlier meeting, added with one click.
private struct SuggestedTagButton: View {
    let tag: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: "plus").font(.system(size: 8, weight: .semibold))
                Text(verbatim: tag).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background {
                let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
                ZStack {
                    if isHovered { shape.fill(Theme.hover) }
                    shape.strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("このタグを付ける")
        .accessibilityLabel(Text("タグ「\(tag)」を付ける"))
    }
}

/// Drawn by SwiftUI: a plain field's own placeholder ignores `foregroundStyle` and reads like typed text.
private struct FieldPlaceholder: View {
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

/// Lays its views out in rows, starting a new row when the next one doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(subviews, maxWidth: proposal.width ?? .infinity)
        return CGSize(
            width: frames.reduce(0) { max($0, $1.maxX) }, height: frames.reduce(0) { max($0, $1.maxY) })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(subviews, maxWidth: bounds.width)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = CGSize(width: min(ideal.width, maxWidth), height: ideal.height)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}
