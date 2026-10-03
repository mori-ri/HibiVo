import Foundation
import Testing

@testable import HibiVoKit

@Suite struct MarkdownEditingTests {
    /// Applies a style with the selection given by `[` and `]` (or a caret `|`) in `marked`, and
    /// returns the result with the new selection marked the same way.
    private func run(_ style: MarkdownStyle, _ marked: String) -> String {
        let (text, selection) = parse(marked)
        return render(MarkdownEditing.apply(style, to: text, selection: selection), on: text)
    }

    private func newline(_ marked: String) -> String? {
        let (text, selection) = parse(marked)
        return MarkdownEditing.lineBreak(in: text, selection: selection).map { render($0, on: text) }
    }

    private func indent(_ marked: String, outdent: Bool = false) -> String {
        let (text, selection) = parse(marked)
        return render(MarkdownEditing.indent(in: text, selection: selection, outdent: outdent), on: text)
    }

    private func parse(_ marked: String) -> (String, NSRange) {
        let ns = marked as NSString
        let caret = ns.range(of: "|")
        if caret.location != NSNotFound {
            return (ns.replacingCharacters(in: caret, with: ""), NSRange(location: caret.location, length: 0))
        }
        let start = ns.range(of: "[").location
        let text = marked.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        let end = (marked as NSString).range(of: "]").location - 1
        return (text, NSRange(location: start, length: end - start))
    }

    private func render(_ edit: MarkdownEdit, on text: String) -> String {
        let result = edit.applied(to: text) as NSString
        if edit.selection.length == 0 {
            return result.replacingCharacters(in: edit.selection, with: "|")
        }
        let closed = result.replacingCharacters(in: NSRange(location: NSMaxRange(edit.selection), length: 0), with: "]")
        return (closed as NSString).replacingCharacters(
            in: NSRange(location: edit.selection.location, length: 0), with: "[")
    }

    @Test func caretLineGetsAMarkerAndKeepsItsPlace() {
        #expect(run(.bulletList, "予|算") == "- 予|算")
        #expect(run(.checklist, "|") == "- [ ] |")
        #expect(run(.heading, "a\n議|題\nb") == "a\n### 議|題\nb")
    }

    @Test func sameStyleAgainRemovesIt() {
        #expect(run(.bulletList, "- 予|算") == "予|算")
        #expect(run(.checklist, "- [x] 済|み") == "済|み")
    }

    @Test func anotherStyleReplacesTheMarker() {
        #expect(run(.checklist, "- 連絡|") == "- [ ] 連絡|")
        #expect(run(.bulletList, "  1. 連絡|") == "  - 連絡|")
    }

    @Test func selectedLinesAreNumberedSkippingBlankOnes() {
        #expect(run(.numberedList, "[a\n\nb\nc]\n") == "[1. a\n\n2. b\n3. c]\n")
        #expect(run(.numberedList, "[1. a\n2. b]") == "[a\nb]")
    }

    @Test func boldWrapsAndUnwraps() {
        #expect(run(.bold, "大[事]な") == "大**[事]**な")
        #expect(run(.bold, "大**[事]**な") == "大[事]な")
        #expect(run(.bold, "大[**事**]な") == "大[事]な")
        #expect(run(.bold, "a|") == "a**|**")
    }

    @Test func returnContinuesAList() {
        #expect(newline("- 予算|") == "- 予算\n- |")
        #expect(newline("  3. 予算|") == "  3. 予算\n  4. |")
        #expect(newline("- [x] 済み|") == "- [x] 済み\n- [ ] |")
    }

    @Test func returnOnAnEmptyItemEndsTheList() {
        #expect(newline("- a\n- |") == "- a\n|")
        #expect(newline("- a\n- [ ] |") == "- a\n|")
    }

    @Test func tabIndentsTheLineWhereverTheCaretIs() {
        #expect(indent("- a\n- b|") == "- a\n    - b|")
        #expect(indent("- |b") == "    - |b")
        #expect(indent("|") == "    |")
    }

    @Test func tabIndentsSelectedLinesButNotBlankOnes() {
        #expect(indent("[- a\n\n- b]\n") == "[    - a\n\n    - b]\n")
    }

    @Test func shiftTabOutdentsByOneLevel() {
        #expect(indent("        - b|", outdent: true) == "    - b|")
        #expect(indent("  - |b", outdent: true) == "- |b")
        #expect(indent("\t- b|", outdent: true) == "- b|")
        #expect(indent("- b|", outdent: true) == "- b|")
        // The caret never moves before the start of the line.
        #expect(indent("  |  - b", outdent: true) == "|- b")
    }

    @Test func returnKeepsTheIndentOfANestedItem() {
        #expect(newline("    - b|") == "    - b\n    - |")
    }

    @Test func returnOutsideAListIsLeftToTheTextView() {
        #expect(newline("ただの文|") == nil)
        #expect(newline("### 見出し|") == nil)
        #expect(newline("|- 先頭") == nil)
        #expect(newline("-1 ではない|") == nil)
    }
}
