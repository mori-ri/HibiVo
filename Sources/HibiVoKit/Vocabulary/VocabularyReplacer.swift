import Foundation

/// Deterministic dictionary pass: replaces registered spoken forms with the preferred spelling.
///
/// Runs before LLM cleanup so the Raw mode benefits too. Longer forms are replaced first so
/// "アップシンクAPI" style overlaps resolve to the most specific entry.
///
/// Matching ignores the difference between hiragana and katakana and between full- and half-width
/// forms, because STT picks its own script: a spoken form registered as "ひびぼ" also catches
/// "ヒビボ" and "ﾋﾋﾞﾎﾞ". It also tolerates the small spelling differences STT makes in a word it
/// doesn't know: "ヂ"/"ジ" and "ヅ"/"ズ" are the same, and spaces, "・" and "ー" inside the word are
/// skipped, so "ミカヅキ" catches "ミカズキ" and "AWSラムダ" catches "AWS ラムダ". Raw mode
/// and failed cleanup have no LLM to fix a near miss, so this pass alone has to turn the hinted
/// katakana reading back into the preferred spelling. Text that isn't replaced is left exactly as it
/// was. Short kana forms (`VocabularyEntry.contextualForms`) are never replaced here; cleanup decides
/// them in context.
public enum VocabularyReplacer {
    public static func apply(_ entries: [VocabularyEntry], to text: String) -> String {
        let rules =
            entries
            .flatMap { entry in entry.replaceableForms.map { (from: KanaFolding.matchKeys($0), to: entry.preferred) } }
            .filter { !$0.from.isEmpty }
            .sorted { $0.from.count > $1.from.count }
        guard !rules.isEmpty else { return text }

        let characters = Array(text)
        let keys = characters.map(KanaFolding.key)
        // Single left-to-right scan so a replacement is never re-matched by a shorter rule.
        var result = ""
        var index = 0
        scan: while index < characters.count {
            if !KanaFolding.isSkippable(keys[index]) {
                for rule in rules {
                    guard let end = match(rule.from, in: keys, at: index) else { continue }
                    result += rule.to
                    index = end
                    continue scan
                }
            }
            result.append(characters[index])
            index += 1
        }
        return result
    }

    /// The index just past `rule` matched at `start`, skipping spaces and marks between its characters.
    private static func match(_ rule: [String], in keys: [String], at start: Int) -> Int? {
        var index = start
        for (offset, key) in rule.enumerated() {
            if offset > 0 {
                while index < keys.count, KanaFolding.isSkippable(keys[index]) { index += 1 }
            }
            guard index < keys.count, keys[index] == key else { return nil }
            index += 1
        }
        // A long vowel mark after the last kana still belongs to the word ("ヒビボー" for "ヒビボ").
        if let last = rule.last, KanaFolding.isKatakana(last) {
            while index < keys.count, keys[index] == KanaFolding.longVowelMark { index += 1 }
        }
        return index
    }
}

/// Folds Japanese script variants to one form for comparison. Pure so it can be unit tested.
enum KanaFolding {
    /// Compatibility forms folded (full-width "Ａ" → "A", half-width "ｱ" → "ア"), then hiragana → katakana,
    /// then "ヂ" → "ジ" and "ヅ" → "ズ", which sound the same and which STT rarely writes.
    static func key(_ character: Character) -> String {
        switch katakana(String(character).precomposedStringWithCompatibilityMapping) {
        case "ヂ": "ジ"
        case "ヅ": "ズ"
        case let key: key
        }
    }

    static func keys(_ string: String) -> [String] {
        string.map(key)
    }

    static let longVowelMark = "ー"

    /// Keys a registered form is matched by: `keys` without the characters matching skips over.
    static func matchKeys(_ string: String) -> [String] {
        keys(string).filter { !isSkippable($0) }
    }

    /// Characters STT puts inside a word at will: spaces (Soniox spaces out Latin words), "・" and "ー".
    static func isSkippable(_ key: String) -> Bool {
        key == longVowelMark || key == "・" || key.allSatisfy(\.isWhitespace)
    }

    /// Whether a folded key is katakana, including the prolonged sound mark and iteration marks.
    static func isKatakana(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { (0x30A1...0x30FE).contains($0.value) && $0.value != 0x30FB }
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
