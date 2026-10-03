import Foundation

/// Adds the words a user corrected after a paste to the dictionary and shows them in the HUD for
/// a few seconds, where a click undoes them. The notice stays while the pointer is over it, so
/// there is time to read it before deciding.
@MainActor
public final class CorrectionLearner {
    static let noticeDuration: Duration = .seconds(10)

    private let vocabulary: VocabularyStore
    private let state: AppState
    private var dismiss: Task<Void, Never>?

    public init(vocabulary: VocabularyStore, state: AppState) {
        self.vocabulary = vocabulary
        self.state = state
    }

    public func learn(inserted: String, edited: String) {
        let learned = CorrectionExtractor.corrections(from: inserted, to: edited).compactMap(vocabulary.learn)
        guard !learned.isEmpty else { return }
        state.learnedVocabulary = learned
        scheduleDismiss()
    }

    /// Holds the notice while the pointer is over it and restarts the countdown when it leaves.
    public func setHovering(_ hovering: Bool) {
        guard !state.learnedVocabulary.isEmpty else { return }
        if hovering {
            dismiss?.cancel()
        } else {
            scheduleDismiss()
        }
    }

    /// Takes back the words on show, newest change first.
    public func undoShown() {
        dismiss?.cancel()
        for learning in state.learnedVocabulary.reversed() { vocabulary.undo(learning) }
        state.learnedVocabulary = []
    }

    private func scheduleDismiss() {
        dismiss?.cancel()
        dismiss = Task { [state] in
            try? await Task.sleep(for: Self.noticeDuration)
            guard !Task.isCancelled else { return }
            state.learnedVocabulary = []
        }
    }
}
