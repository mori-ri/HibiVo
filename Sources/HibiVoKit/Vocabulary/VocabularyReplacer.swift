import Foundation

/// Deterministic dictionary pass: replaces registered spoken forms with the preferred spelling.
///
/// Runs before LLM cleanup so the Raw mode benefits too. Longer forms are replaced first so
/// "アップシンクAPI" style overlaps resolve to the most specific entry.
///
/// Matching ignores the difference between hiragana and katakana and between full- and half-width
/// forms, because STT picks its own script: a spoken form registered as "ひびぼ" also catches
/// "ヒビボ" and "ﾋﾋﾞﾎﾞ". It also tolerates two differences STT makes in a word it doesn't know:
/// "ヂ"/"ジ" and "ヅ"/"ズ" are the same, and a space where Latin letters meet kana is optional, so
/// "ミカヅキ" catches "ミカズキ" and "AWSラムダ" catches "AWS ラムダ" (Soniox spaces out Latin words).
/// Raw mode and failed cleanup have no LLM to fix a near miss, so this pass alone has to turn the
/// hinted katakana reading back into the preferred spelling. "ー" and "・" are not ignored: they tell
/// words apart ("バッター" and "バッタ"). Text that isn't replaced is left exactly as it was. Short
/// kana forms (`VocabularyEntry.contextualForms`) are never replaced here; cleanup decides them in
/// context.
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
            for rule in rules {
                guard let end = match(rule.from, in: keys, at: index) else { continue }
                result += rule.to
                index = end
                continue scan
            }
            result.append(characters[index])
            index += 1
        }
        return result
    }

    /// The index just past `rule` matched at `start`, skipping spaces where Latin letters meet kana.
    private static func match(_ rule: [String], in keys: [String], at start: Int) -> Int? {
        var index = start
        var previous: String?
        for key in rule {
            if let previous, KanaFolding.isScriptBoundary(previous, key) {
                while index < keys.count, KanaFolding.isSpace(keys[index]) { index += 1 }
            }
            guard index < keys.count, keys[index] == key else { return nil }
            index += 1
            previous = key
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

    /// Keys a registered form is matched by: `keys` without the optional spaces where Latin letters
    /// meet kana, so "AWS ラムダ" and "AWSラムダ" match the same text. Other spaces are kept.
    static func matchKeys(_ string: String) -> [String] {
        let keys = keys(string)
        return keys.indices.compactMap { index in
            guard isSpace(keys[index]) else { return keys[index] }
            let before = keys[..<index].last { !isSpace($0) }
            let after = keys[(index + 1)...].first { !isSpace($0) }
            if let before, let after, isScriptBoundary(before, after) { return nil }
            return keys[index]
        }
    }

    /// Spaces only; a line break is never skipped, so a match never joins two lines.
    static func isSpace(_ key: String) -> Bool {
        key == " " || key == "\t"
    }

    /// Whether one side is a Latin letter or digit and the other isn't (and neither is a space).
    static func isScriptBoundary(_ lhs: String, _ rhs: String) -> Bool {
        !isSpace(lhs) && !isSpace(rhs) && isLatin(lhs) != isLatin(rhs)
    }

    static func isLatin(_ key: String) -> Bool {
        key.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
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
