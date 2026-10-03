import Foundation

/// A word the user corrected after it was inserted: `original` is what HibiVo wrote, `corrected`
/// what the user changed it to.
public struct VocabularyCorrection: Hashable, Sendable {
    public var original: String
    public var corrected: String

    public init(original: String, corrected: String) {
        self.original = original
        self.corrected = corrected
    }
}

/// Finds the misrecognised words a user fixed by comparing inserted text with its edited version.
/// Pure so it can be unit tested.
///
/// Character diff first, then each changed span grows to the whole run of Latin letters, katakana
/// or kanji around it, so fixing "シンク" in "アップシンク" yields the word "アップシンク". Hiragana
/// runs don't grow: they are mostly particles and okurigana, which would drag the next word in.
/// Most edits are not vocabulary fixes, so the result is filtered hard: a rewrite (many spans, or
/// most of the text changed in several places), punctuation, numbers, okurigana, script-only
/// changes and short kana (`VocabularyEntry.needsContext`) are dropped, and so is a pair that
/// doesn't sound alike, since STT errors sound like the right word while content edits
/// ("明日" → "今日") don't. Only nouns are kept: a verb or adjective ("早く" → "速く") is
/// dropped, because its kanji alone is not a word the dictionary can replace.
public enum CorrectionExtractor {
    static let maxSpans = 3
    static let maxTermLength = 20
    /// Above this share of changed characters, only a single-span edit (one word) is accepted.
    static let rewriteRatio = 0.5
    static let minimumSimilarity = 0.5

    public static func corrections(from original: String, to edited: String) -> [VocabularyCorrection] {
        let a = Array(original)
        let b = Array(edited)
        guard a != b else { return [] }
        var spans = expand(diff(a, b), a, b)
        if let last = spans.last, last.a.upperBound == a.count, last.b.upperBound == b.count {
            spans[spans.count - 1].b = last.b.lowerBound..<wordEnd(b, from: last.b.lowerBound)
        }
        guard !spans.isEmpty, spans.count <= maxSpans else { return [] }
        let changed = spans.reduce(0) { $0 + $1.a.count }
        if spans.count > 1, Double(changed) > Double(a.count) * rewriteRatio { return [] }

        var seen = Set<VocabularyCorrection>()
        return spans.compactMap { span in
            let correction = VocabularyCorrection(
                original: trim(String(a[span.a])), corrected: trim(String(b[span.b])))
            let leading = b[span.b].prefix { $0.unicodeScalars.allSatisfy(trimmed.contains) }.count
            let end = span.b.lowerBound + leading + correction.corrected.count
            guard isVocabulary(correction), !isInflected(b, wordEnd: end), seen.insert(correction).inserted
            else { return nil }
            return correction
        }
    }

    // MARK: - Diff

    struct Span: Equatable {
        var a: Range<Int>
        var b: Range<Int>
    }

    /// Changed spans between `a` and `b`; everything outside them is matched character for character.
    static func diff(_ a: [Character], _ b: [Character]) -> [Span] {
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var spans: [Span] = []
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            let start = (i, j)
            while i < a.count, removed.contains(i) { i += 1 }
            while j < b.count, inserted.contains(j) { j += 1 }
            if start == (i, j) {
                i += 1
                j += 1
            } else {
                spans.append(Span(a: start.0..<i, b: start.1..<j))
            }
        }
        return spans
    }

    /// Grows each span over matched neighbours of the same word script, then merges spans that meet.
    static func expand(_ spans: [Span], _ a: [Character], _ b: [Character]) -> [Span] {
        var merged: [Span] = []
        for (index, var span) in spans.enumerated() {
            // Outside the spans the texts match, so a neighbour is the same character on both sides.
            let floor = merged.last?.a.upperBound ?? 0
            let ceiling = index + 1 < spans.count ? spans[index + 1].a.lowerBound : a.count
            while span.a.lowerBound > floor,
                joins(a[span.a.lowerBound - 1], [first(a, span.a), first(b, span.b)])
            {
                span = Span(a: span.a.lowerBound - 1..<span.a.upperBound, b: span.b.lowerBound - 1..<span.b.upperBound)
            }
            while span.a.upperBound < ceiling,
                joins(a[span.a.upperBound], [last(a, span.a), last(b, span.b)])
            {
                span = Span(a: span.a.lowerBound..<span.a.upperBound + 1, b: span.b.lowerBound..<span.b.upperBound + 1)
            }
            if let previous = merged.last, span.a.lowerBound <= previous.a.upperBound {
                merged[merged.count - 1] = Span(
                    a: previous.a.lowerBound..<span.a.upperBound, b: previous.b.lowerBound..<span.b.upperBound)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// Where the word starting at `start` ends. Text the user typed right after the inserted text
    /// joins the last span; this keeps only the fix itself, up to a space, punctuation or the
    /// hiragana that follows a Latin or katakana word ("AppSync を使う", "AppSyncを使う" → "AppSync").
    static func wordEnd(_ characters: [Character], from start: Int) -> Int {
        var previous: Script?
        for index in start..<characters.count {
            let script = Script(characters[index])
            if characters[index].isWhitespace || script == .other && previous != nil { return index }
            if script == .hiragana, previous == .latin || previous == .katakana { return index }
            previous = script
        }
        return characters.count
    }

    private static func first(_ characters: [Character], _ range: Range<Int>) -> Character? {
        range.isEmpty ? nil : characters[range.lowerBound]
    }

    private static func last(_ characters: [Character], _ range: Range<Int>) -> Character? {
        range.isEmpty ? nil : characters[range.upperBound - 1]
    }

    /// Whether a matched neighbour belongs to the same word as the changed characters next to it.
    private static func joins(_ neighbour: Character, _ edges: [Character?]) -> Bool {
        let script = Script(neighbour)
        return script.isWord && edges.contains { $0.map(Script.init) == script }
    }

    // MARK: - Filtering

    private static let trimmed = CharacterSet.whitespaces.union(.punctuationCharacters).union(.symbols)

    private static func trim(_ string: String) -> String {
        string.trimmingCharacters(in: trimmed)
    }

    static func isVocabulary(_ correction: VocabularyCorrection) -> Bool {
        let (original, corrected) = (correction.original, correction.corrected)
        guard !original.isEmpty, !corrected.isEmpty,
            original.count <= maxTermLength, corrected.count <= maxTermLength,
            !original.contains(where: \.isNewline), !corrected.contains(where: \.isNewline),
            // Numbers and punctuation-only fixes aren't words.
            corrected.unicodeScalars.contains(where: CharacterSet.letters.contains),
            // Okurigana and particles.
            !corrected.allSatisfy({ Script($0) == .hiragana }),
            // Same text in another script or width; the dictionary can't tell those apart.
            KanaFolding.keys(original) != KanaFolding.keys(corrected),
            !VocabularyEntry.needsContext(original)
        else { return false }
        return isAcronym(corrected) || similarity(original, corrected) >= minimumSimilarity
    }

    /// Whether the word ending at `wordEnd` is the stem of a verb or adjective. Okurigana stays
    /// out of the spans, so "速く" yields "速"; the system tokenizer keeps an inflected word in one
    /// token ("速く", "書い", "美しい") but splits a noun from what follows ("校正 | する", "会議 | に").
    static func isInflected(_ characters: [Character], wordEnd: Int) -> Bool {
        guard wordEnd > 0, wordEnd < characters.count else { return false }
        let text = String(characters) as NSString
        let end = String(characters[..<wordEnd]).utf16.count
        let tokenizer = CFStringTokenizerCreate(
            nil, text, CFRange(location: 0, length: text.length), kCFStringTokenizerUnitWord,
            Locale(identifier: "ja") as CFLocale)
        guard !CFStringTokenizerGoToTokenAtIndex(tokenizer, end - 1).isEmpty else { return false }
        let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
        return range.location + range.length > end
    }

    /// "AWS" read out as "エーダブリューエス" sounds nothing like its letters' romaji.
    private static func isAcronym(_ string: String) -> Bool {
        (2...6).contains(string.count)
            && string.unicodeScalars.allSatisfy {
                CharacterSet.uppercaseLetters.contains($0) || ("0"..."9").contains($0)
            }
    }

    // MARK: - Sound

    /// How alike two words sound, 0...1: edit distance between their consonant skeletons.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        var x = skeleton(lhs)
        var y = skeleton(rhs)
        // Vowel-only words ("あい") have no skeleton; compare the whole reading.
        if x.isEmpty || y.isEmpty {
            x = Array(romaji(lhs))
            y = Array(romaji(rhs))
        }
        guard let longest = [x.count, y.count].max(), longest > 0 else { return 0 }
        return 1 - Double(editDistance(x, y)) / Double(longest)
    }

    /// Romaji with vowels and doubled letters dropped and Japanese-English confusions folded
    /// ("l"/"r", "v"/"b", "c"/"k"), so "アップシンク" (appushinku) and "AppSync" both become "psnk".
    static func skeleton(_ string: String) -> [Character] {
        var result: [Character] = []
        for character in romaji(string) {
            let folded: Character =
                switch character {
                case "l": "r"
                case "v": "b"
                case "c", "q": "k"
                default: character
                }
            if "aeiouy".contains(folded) { continue }
            // "sh"/"ch"/"ts" → "s"/"k"/"t": romaji spells one sound with an extra "h" or "s".
            if folded == "h", let last = result.last, "skt".contains(last) { continue }
            if folded == "s", result.last == "t" { continue }
            if result.last != folded { result.append(folded) }
        }
        return result
    }

    /// Lowercase ASCII romaji. Japanese goes through the system tokenizer's Latin transcription.
    static func romaji(_ string: String) -> String {
        let text = string as NSString
        let tokenizer = CFStringTokenizerCreate(
            nil, text, CFRange(location: 0, length: text.length), kCFStringTokenizerUnitWord,
            Locale(identifier: "ja") as CFLocale)
        var result = ""
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let latin =
                CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription)
                as? String
            result += latin ?? text.substring(with: NSRange(location: range.location, length: range.length))
        }
        return String(
            result.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
                .unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
                .map(Character.init))
    }

    private static func editDistance(_ x: [Character], _ y: [Character]) -> Int {
        var previous = Array(0...y.count)
        for (i, cx) in x.enumerated() {
            var current = [i + 1]
            for (j, cy) in y.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (cx == cy ? 0 : 1)))
            }
            previous = current
        }
        return previous[y.count]
    }
}

/// The script of one character, for finding word boundaries in Japanese text.
enum Script: Equatable {
    case latin, hiragana, katakana, kanji, other

    init(_ character: Character) {
        let folded = String(character).precomposedStringWithCompatibilityMapping.unicodeScalars
        guard let scalar = folded.first, folded.count == 1 else {
            self = .other
            return
        }
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: self = .latin
        case 0x3041...0x309F: self = .hiragana
        case 0x30FB: self = .other  // "・" separates words.
        case 0x30A0...0x30FF: self = .katakana
        case 0x3005, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: self = .kanji
        default: self = .other
        }
    }

    /// Scripts a vocabulary word is written in. Hiragana is left out: see `CorrectionExtractor`.
    var isWord: Bool {
        switch self {
        case .latin, .katakana, .kanji: true
        case .hiragana, .other: false
        }
    }
}
