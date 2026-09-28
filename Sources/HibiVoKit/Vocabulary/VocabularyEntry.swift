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

    /// Spoken forms as STT hints. Katakana, because that is how STT writes a name it doesn't know.
    public var readings: [String] {
        spokenForms.map(KanaFolding.katakana)
    }

    var promptTerm: CleanupPromptBuilder.Term {
        CleanupPromptBuilder.Term(preferred: preferred, spokenForms: spokenForms)
    }
}
