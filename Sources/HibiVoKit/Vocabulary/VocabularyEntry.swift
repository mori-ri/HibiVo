import Foundation

/// A user dictionary entry, e.g. preferred "AppSync", spoken "アップシンク", aliases ["アップ シンク"].
public struct VocabularyEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var preferred: String
    /// How the term tends to come out of STT when misrecognised. Optional.
    public var spoken: String
    public var aliases: [String]

    public init(id: UUID = UUID(), preferred: String, spoken: String = "", aliases: [String] = []) {
        self.id = id
        self.preferred = preferred
        self.spoken = spoken
        self.aliases = aliases
    }

    /// Non-empty spoken form and aliases, i.e. everything that should become `preferred`.
    public var spokenForms: [String] {
        ([spoken] + aliases)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != preferred }
    }

    /// Spoken forms safe to replace without context.
    public var replaceableForms: [String] {
        spokenForms.filter { !Self.needsContext($0) }
    }

    /// Short kana forms such as "あい" for "AI": they are also everyday words and appear inside
    /// other words ("あいさつ"), so only cleanup, which sees the context, may turn them into `preferred`.
    public var contextualForms: [String] {
        spokenForms.filter(Self.needsContext)
    }

    /// Replaceable forms as STT hints. Katakana, because that is how STT writes a name it doesn't know.
    /// Contextual forms are left out so a hint like "アイ" doesn't pull "愛" toward katakana.
    public var readings: [String] {
        replaceableForms.map(KanaFolding.katakana)
    }

    var promptTerm: CleanupPromptBuilder.Term {
        CleanupPromptBuilder.Term(
            preferred: preferred, spokenForms: replaceableForms, contextualForms: contextualForms)
    }

    static let contextualLengthLimit = 2

    /// Kana-only forms of at most `contextualLengthLimit` characters. Kanji and Latin forms of the
    /// same length are specific enough to replace.
    static func needsContext(_ form: String) -> Bool {
        let keys = KanaFolding.keys(form)
        return keys.count <= contextualLengthLimit && keys.allSatisfy(KanaFolding.isKatakana)
    }
}
