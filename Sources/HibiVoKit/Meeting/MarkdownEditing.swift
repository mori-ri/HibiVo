import Foundation

/// The formatting buttons of the meeting notes window.
public enum MarkdownStyle: CaseIterable, Sendable {
    case heading, bold, bulletList, numberedList, checklist
}

/// One replacement in the notes text, in NSString (UTF-16) offsets as NSTextView uses them.
struct MarkdownEdit: Equatable {
    var range: NSRange
    var replacement: String
    /// The selection after the edit.
    var selection: NSRange

    func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}

/// Plain-text Markdown helpers for the notes window: toggling line markers and bold, and continuing
/// a list on Return. Pure so it can be unit tested.
enum MarkdownEditing {
    /// The marker at the start of a line, after its indentation.
    enum Marker: Equatable {
        case heading(String)
        case bullet(Character)
        case numbered(Int)
        case checkbox(checked: Bool)

        var text: String {
            switch self {
            case .heading(let hashes): "\(hashes) "
            case .bullet(let symbol): "\(symbol) "
            case .numbered(let number): "\(number). "
            case .checkbox(let checked): checked ? "- [x] " : "- [ ] "
            }
        }

        /// The marker for the line that follows on Return; nil for headings, which don't continue.
        var next: Marker? {
            switch self {
            case .heading: nil
            case .bullet: self
            case .numbered(let number): .numbered(number + 1)
            case .checkbox: .checkbox(checked: false)
            }
        }
    }

    struct Line {
        var indent: Substring
        var marker: Marker?
        var content: Substring

        var prefixLength: Int { indent.utf16.count + (marker?.text.utf16.count ?? 0) }
    }

    /// The heading level the notes use: the notes sit under `## メモ` in the saved files.
    static let headingMarker = Marker.heading("###")
    /// One level of indentation. Four spaces nest a list item under any kind of list marker.
    static let indentUnit = "    "

    static func parse(_ line: Substring) -> Line {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(indent.count)
        for (prefix, checked) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true)] where rest.hasPrefix(prefix) {
            return Line(indent: indent, marker: .checkbox(checked: checked), content: rest.dropFirst(prefix.count))
        }
        if let symbol = rest.first, "-*+".contains(symbol), rest.dropFirst().first == " " {
            return Line(indent: indent, marker: .bullet(symbol), content: rest.dropFirst(2))
        }
        let digits = rest.prefix(while: \.isASCIIDigit)
        if (1...9).contains(digits.count), rest.dropFirst(digits.count).hasPrefix(". "), let number = Int(digits) {
            return Line(indent: indent, marker: .numbered(number), content: rest.dropFirst(digits.count + 2))
        }
        let hashes = rest.prefix { $0 == "#" }
        if (1...6).contains(hashes.count), rest.dropFirst(hashes.count).first == " " {
            return Line(indent: indent, marker: .heading(String(hashes)), content: rest.dropFirst(hashes.count + 1))
        }
        return Line(indent: indent, marker: nil, content: rest)
    }

    static func apply(_ style: MarkdownStyle, to text: String, selection: NSRange) -> MarkdownEdit {
        style == .bold ? toggleBold(in: text, selection: selection) : toggleLines(style, in: text, selection: selection)
    }

    /// Return inside a list item: starts the next item, or ends the list when the item is still empty.
    /// nil when Return should just insert a line break.
    static func lineBreak(in text: String, selection: NSRange) -> MarkdownEdit? {
        guard selection.length == 0 else { return nil }
        let ns = text as NSString
        let lineRange = ns.lineRange(for: selection)
        let line = parse(Substring(lineContent(ns, lineRange)))
        guard let marker = line.marker, let next = marker.next,
            selection.location - lineRange.location >= line.prefixLength
        else { return nil }
        if line.content.allSatisfy(\.isWhitespace) {
            let range = NSRange(location: lineRange.location, length: line.prefixLength)
            return MarkdownEdit(range: range, replacement: "", selection: NSRange(location: range.location, length: 0))
        }
        let insertion = "\n\(line.indent)\(next.text)"
        return MarkdownEdit(
            range: selection, replacement: insertion,
            selection: NSRange(location: selection.location + insertion.utf16.count, length: 0))
    }

    /// Tab and Shift-Tab: indents or outdents every selected line by one level. Blank lines in a
    /// multi-line selection are left alone.
    static func indent(in text: String, selection: NSRange, outdent: Bool) -> MarkdownEdit {
        let ns = text as NSString
        let range = ns.lineRange(for: selection)
        let block = ns.substring(with: range)
        let endsWithNewline = block.hasSuffix("\n")
        var lines = (endsWithNewline ? String(block.dropLast()) : block)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let caretOffset = selection.location - range.location
        var firstLineShift = 0
        for index in lines.indices where lines.count == 1 || !lines[index].allSatisfy(\.isWhitespace) {
            let old = lines[index]
            if outdent {
                let removable = old.hasPrefix("\t") ? 1 : old.prefix(indentUnit.count).prefix { $0 == " " }.count
                lines[index] = String(old.dropFirst(removable))
            } else {
                lines[index] = indentUnit + old
            }
            if index == 0 { firstLineShift = lines[0].utf16.count - old.utf16.count }
        }
        let newBlock = lines.joined(separator: "\n")
        let newSelection =
            selection.length == 0 && lines.count == 1
            ? NSRange(location: range.location + max(0, caretOffset + firstLineShift), length: 0)
            : NSRange(location: range.location, length: newBlock.utf16.count)
        return MarkdownEdit(
            range: range, replacement: newBlock + (endsWithNewline ? "\n" : ""), selection: newSelection)
    }

    // MARK: - Private

    private static func matches(_ marker: Marker?, _ style: MarkdownStyle) -> Bool {
        switch (style, marker) {
        case (.heading, .heading?), (.bulletList, .bullet?), (.numberedList, .numbered?), (.checklist, .checkbox?):
            true
        default: false
        }
    }

    private static func marker(for style: MarkdownStyle, number: Int) -> Marker? {
        switch style {
        case .heading: headingMarker
        case .bulletList: .bullet("-")
        case .numberedList: .numbered(number)
        case .checklist: .checkbox(checked: false)
        case .bold: nil
        }
    }

    /// Adds the style's marker to every selected line, replacing another kind of marker, or removes it
    /// when every line already has it. Blank lines are left alone unless nothing else is selected.
    private static func toggleLines(_ style: MarkdownStyle, in text: String, selection: NSRange) -> MarkdownEdit {
        let ns = text as NSString
        let range = ns.lineRange(for: selection)
        let block = ns.substring(with: range)
        let endsWithNewline = block.hasSuffix("\n")
        var lines = (endsWithNewline ? String(block.dropLast()) : block)
            .split(separator: "\n", omittingEmptySubsequences: false).map(parse)
        let nonBlank = lines.indices.filter { lines[$0].marker != nil || !lines[$0].content.allSatisfy(\.isWhitespace) }
        let targets = nonBlank.isEmpty ? Array(lines.indices) : nonBlank
        let removing = targets.allSatisfy { matches(lines[$0].marker, style) }
        let caretOffset = selection.location - range.location
        let oldPrefix = lines.first?.prefixLength ?? 0
        for (number, index) in targets.enumerated() {
            lines[index].marker = removing ? nil : marker(for: style, number: number + 1)
        }
        let newBlock = lines.map { "\($0.indent)\($0.marker?.text ?? "")\($0.content)" }.joined(separator: "\n")
        let replacement = newBlock + (endsWithNewline ? "\n" : "")
        let newSelection: NSRange
        if selection.length == 0, lines.count == 1 {
            // Keep the caret where it was in the text, but never inside the marker.
            let newPrefix = lines[0].prefixLength
            let offset = caretOffset < oldPrefix ? newPrefix : caretOffset + newPrefix - oldPrefix
            newSelection = NSRange(location: range.location + offset, length: 0)
        } else {
            newSelection = NSRange(location: range.location, length: newBlock.utf16.count)
        }
        return MarkdownEdit(range: range, replacement: replacement, selection: newSelection)
    }

    /// Wraps the selection in `**`, or unwraps it when it already is. With nothing selected, inserts
    /// the pair and puts the caret between them.
    private static func toggleBold(in text: String, selection: NSRange) -> MarkdownEdit {
        let ns = text as NSString
        let selected = ns.substring(with: selection)
        if selected.count >= 4, selected.hasPrefix("**"), selected.hasSuffix("**") {
            let inner = String(selected.dropFirst(2).dropLast(2))
            return MarkdownEdit(
                range: selection, replacement: inner,
                selection: NSRange(location: selection.location, length: inner.utf16.count))
        }
        let around = NSRange(location: selection.location - 2, length: selection.length + 4)
        if selection.location >= 2, NSMaxRange(around) <= ns.length, selection.length > 0 {
            let surrounding = ns.substring(with: around)
            if surrounding.hasPrefix("**"), surrounding.hasSuffix("**") {
                return MarkdownEdit(
                    range: around, replacement: selected,
                    selection: NSRange(location: around.location, length: selection.length))
            }
        }
        return MarkdownEdit(
            range: selection, replacement: "**\(selected)**",
            selection: NSRange(location: selection.location + 2, length: selection.length))
    }

    /// The line without its line break.
    private static func lineContent(_ ns: NSString, _ lineRange: NSRange) -> String {
        let line = ns.substring(with: lineRange)
        return line.hasSuffix("\n") ? String(line.dropLast()) : line
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
