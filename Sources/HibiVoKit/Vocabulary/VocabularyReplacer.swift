import Foundation

/// Deterministic dictionary pass: replaces registered spoken forms with the preferred spelling.
///
/// Runs before LLM cleanup so the Raw mode benefits too. Longer forms are replaced first so
/// "アップシンクAPI" style overlaps resolve to the most specific entry.
///
/// Matching ignores the difference between hiragana and katakana and between full- and half-width
/// forms, because STT picks its own script: a spoken form registered as "ひびぼ" also catches
/// "ヒビボ" and "ﾋﾋﾞﾎﾞ". Text that isn't replaced is left exactly as it was.
public enum VocabularyReplacer {
    public static func apply(_ entries: [VocabularyEntry], to text: String) -> String {
        let rules =
            entries
            .flatMap { entry in entry.spokenForms.map { (from: KanaFolding.keys($0), to: entry.preferred) } }
            .filter { !$0.from.isEmpty }
            .sorted { $0.from.count > $1.from.count }
        guard !rules.isEmpty else { return text }

        let characters = Array(text)
        let keys = characters.map(KanaFolding.key)
        // Single left-to-right scan so a replacement is never re-matched by a shorter rule.
        var result = ""
        var index = 0
        scan: while index < characters.count {
            for rule in rules where keys[index...].starts(with: rule.from) {
                result += rule.to
                index += rule.from.count
                continue scan
            }
            result.append(characters[index])
            index += 1
        }
        return result
    }
}

/// Folds Japanese script variants to one form for comparison. Pure so it can be unit tested.
enum KanaFolding {
    /// Compatibility forms folded (full-width "Ａ" → "A", half-width "ｱ" → "ア"), then hiragana → katakana.
    static func key(_ character: Character) -> String {
        katakana(String(character).precomposedStringWithCompatibilityMapping)
    }

    static func keys(_ string: String) -> [String] {
        string.map(key)
    }

    /// Hiragana (ぁ–ゖ, ゝゞ) to katakana; everything else unchanged.
    static func katakana(_ string: String) -> String {
        String(
            String.UnicodeScalarView(
                string.unicodeScalars.map { scalar in
                    switch scalar.value {
                    case 0x3041...0x3096, 0x309D...0x309E: Unicode.Scalar(scalar.value + 0x60) ?? scalar
                    default: scalar
                    }
                }))
    }
}
