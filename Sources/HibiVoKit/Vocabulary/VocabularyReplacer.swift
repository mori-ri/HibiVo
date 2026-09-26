import Foundation

/// Deterministic dictionary pass: replaces registered spoken forms with the preferred spelling.
///
/// Runs before LLM cleanup so the Raw mode benefits too. Longer forms are replaced first so
/// "アップシンクAPI" style overlaps resolve to the most specific entry.
public enum VocabularyReplacer {
    public static func apply(_ entries: [VocabularyEntry], to text: String) -> String {
        let rules = entries
            .flatMap { entry in entry.spokenForms.map { (from: $0, to: entry.preferred) } }
            .sorted { $0.from.count > $1.from.count }
        guard !rules.isEmpty else { return text }

        // Single left-to-right scan so a replacement is never re-matched by a shorter rule.
        var result = ""
        var index = text.startIndex
        scan: while index < text.endIndex {
            for rule in rules where text[index...].hasPrefix(rule.from) {
                result += rule.to
                index = text.index(index, offsetBy: rule.from.count)
                continue scan
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }
}
