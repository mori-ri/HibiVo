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

    /// Entries that actually have a preferred spelling.
    public var activeEntries: [VocabularyEntry] {
        entries.filter { !$0.preferred.trimmingCharacters(in: .whitespaces).isEmpty }
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
}
