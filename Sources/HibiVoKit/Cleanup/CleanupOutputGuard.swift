import Foundation

/// Sanity-checks LLM output before it is pasted. Returns nil when the raw transcript should be used.
public enum CleanupOutputGuard {
    public static func validate(
        _ output: String, raw: String, mode: CleanupMode, screenContext: ScreenContext? = nil
    ) -> String? {
        var text = output
        text = removingBlocks(in: text, tags: ["think", "thinking", "reasoning"])
        text = unwrapping(text, tag: "transcript")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = strippingCodeFence(text)
        text = strippingPreamble(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Guard against the model answering the transcript or inventing content.
        let rawCount = raw.count
        // Custom instructions may legitimately lengthen the text, e.g. translating Japanese into English.
        let maxRatio = mode == .prompt || mode == .custom ? 3.0 : 2.0
        if Double(text.count) > Double(rawCount) * maxRatio + 40 { return nil }
        // …or silently dropping most of it. Short inputs are legitimately shortened a lot by filler removal.
        // Custom instructions may ask for a summary; the raw transcript stays in the history.
        if mode != .custom, rawCount >= 30, Double(text.count) < Double(rawCount) * 0.25 { return nil }
        if let screenContext, copiesScreenText(text, from: screenContext, raw: raw) { return nil }
        return text
    }

    /// Sentences shorter than this are too likely to match by chance (greetings, names).
    static let copiedSentenceMinimum = 16

    /// Whether the model added sentences of the surrounding text (a quoted mail, say) on top of what
    /// was said. A sentence the speaker read out, like their own signature in the quoted thread, is
    /// fine even though the transcript spells it differently: the output then stays about as long as
    /// the speech, while a copied quote makes it longer by about the quote's length.
    static func copiesScreenText(_ text: String, from context: ScreenContext, raw: String) -> Bool {
        let sentences = (context.body + "\n" + context.draft).split(whereSeparator: { "\n。！？!?".contains($0) })
        let copied = Set(
            sentences.map { $0.trimmingCharacters(in: .whitespaces) }.filter {
                $0.count >= copiedSentenceMinimum && text.contains($0) && !raw.contains($0)
            })
        guard !copied.isEmpty else { return false }
        let copiedLength = copied.reduce(0) { $0 + $1.count }
        return Double(text.count) >= Double(raw.count) * 0.8 + Double(copiedLength)
    }

    private static func removingBlocks(in text: String, tags: [String]) -> String {
        tags.reduce(text) { result, tag in
            result.replacingOccurrences(
                of: "<\(tag)>[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
    }

    private static func unwrapping(_ text: String, tag: String) -> String {
        text.replacingOccurrences(of: "</?\(tag)>", with: "", options: .regularExpression)
    }

    private static func strippingCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 else { return text }
        var lines = text.components(separatedBy: "\n")
        guard lines.count >= 3 else { return text }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n")
    }

    /// Drops a leading line like 「以下が整形後の文章です：」 or "Here is the cleaned text:".
    private static func strippingPreamble(_ text: String) -> String {
        guard let newline = text.firstIndex(of: "\n") else { return text }
        let first = text[..<newline].trimmingCharacters(in: .whitespaces)
        let looksLikePreamble =
            (first.hasSuffix("：") || first.hasSuffix(":"))
            && ["整形", "修正", "以下", "清書", "Here", "here"].contains { first.contains($0) }
        return looksLikePreamble ? String(text[text.index(after: newline)...]) : text
    }
}
