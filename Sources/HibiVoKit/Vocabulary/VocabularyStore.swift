import Foundation

/// The user dictionary. Small enough to keep in memory; persisted as JSON.
@MainActor
@Observable
public final class VocabularyStore {
    public private(set) var entries: [VocabularyEntry]
    @ObservationIgnored private let file: JSONFileStore<[VocabularyEntry]>

    public convenience init() {
        self.init(file: .appSupport("vocabulary.json"))
    }

    init(file: JSONFileStore<[VocabularyEntry]>) {
        self.file = file
        entries = file.load() ?? []
    }

    /// Enabled entries that actually have a preferred spelling.
    public var activeEntries: [VocabularyEntry] {
        entries.filter { $0.isEnabled && !$0.preferred.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public func add(_ entry: VocabularyEntry) {
        entries.append(entry)
        file.save(entries)
    }

    public func update(_ entry: VocabularyEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        file.save(entries)
    }

    public func remove(ids: Set<VocabularyEntry.ID>) {
        entries.removeAll { ids.contains($0.id) }
        file.save(entries)
    }

    // MARK: - Learning from corrections

    /// Adds a corrected word: as a spoken form of the entry already spelled `corrected`, or as a new
    /// entry. Returns nil, changing nothing, when `canLearn` is false.
    ///
    /// A misrecognition written in kanji ("構成" for "校正") goes to the aliases: the spoken field is
    /// shown as the word's reading, and kanji there reads as a wrong reading.
    @discardableResult
    public func learn(_ correction: VocabularyCorrection) -> VocabularyLearning? {
        guard canLearn(correction) else { return nil }
        let isReading = !correction.original.contains { Script($0) == .kanji }
        guard var entry = entries.first(where: { $0.preferred == correction.corrected }) else {
            let entry =
                isReading
                ? VocabularyEntry(preferred: correction.corrected, spoken: correction.original, origin: .learned)
                : VocabularyEntry(preferred: correction.corrected, aliases: [correction.original], origin: .learned)
            add(entry)
            return VocabularyLearning(correction: correction, change: .added(entry.id))
        }
        let previous = entry
        if isReading, entry.spoken.trimmingCharacters(in: .whitespaces).isEmpty {
            entry.spoken = correction.original
        } else {
            entry.aliases.append(correction.original)
        }
        update(entry)
        return VocabularyLearning(correction: correction, change: .extended(previous: previous))
    }

    /// False when the dictionary already turns `original` into `corrected`, or when `original` is a
    /// registered spelling or another entry's spoken form, which would make two entries fight over
    /// the same text. Also false when `corrected` is a disabled entry: the user turned it off, so
    /// learning must not quietly add to it.
    public func canLearn(_ correction: VocabularyCorrection) -> Bool {
        let key = KanaFolding.matchKeys(correction.original)
        let covers = { (form: String) in KanaFolding.matchKeys(form) == key }
        return !entries.contains {
            covers($0.preferred) || $0.spokenForms.contains(where: covers)
                || !$0.isEnabled && $0.preferred == correction.corrected
        }
    }

    /// Reverts a `learn`. Edits the user made to the entry since are lost with it.
    public func undo(_ learning: VocabularyLearning) {
        switch learning.change {
        case .added(let id): remove(ids: [id])
        case .extended(let previous): update(previous)
        }
    }
}

/// What `VocabularyStore.learn` changed, so it can be undone.
public struct VocabularyLearning: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case added(VocabularyEntry.ID)
        case extended(previous: VocabularyEntry)
    }

    public var correction: VocabularyCorrection
    public var change: Change
}
