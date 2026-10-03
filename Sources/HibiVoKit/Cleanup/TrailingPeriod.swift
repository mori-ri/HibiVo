import Foundation

/// Drops the period that STT and cleanup put after a lone word ("AppSync。", "Lambda."), which
/// gets in the way when dictating into a search box, a form field or the middle of a sentence.
/// Pure so it can be unit tested.
public enum TrailingPeriod {
    /// Longer text is left alone even without other punctuation: it is likely a sentence.
    static let maxWordLength = 20

    public static func trimmed(_ text: String) -> String {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let period = word.last, period == "。" || period == "." else { return text }
        let body = word.dropLast()
        guard let last = body.last, body.count <= maxWordLength,
            !body.contains(where: { $0.isNewline || isPunctuation($0) }),
            // Japanese sentences end in hiragana (です, ました, ね); words end in kanji, katakana or letters.
            Script(last).isWord,
            // An English sentence ends in a letter too, so only a single English word loses its ".".
            period == "。" || !body.contains(where: \.isWhitespace)
        else { return text }
        return String(body)
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        "、。，．,.！？!?…".contains(character)
    }
}
