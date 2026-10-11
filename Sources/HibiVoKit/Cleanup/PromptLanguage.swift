/// Which prompts cleanup and minutes use, chosen by the transcription language in Settings.
/// Japanese keeps a prompt written in Japanese: an English prompt cleaned Japanese up less faithfully in evals.
public enum PromptLanguage: String, Sendable, Equatable, CaseIterable {
    case japanese
    case english

    /// - Parameter transcriptionLanguage: `SettingsStore.language`, e.g. "ja" or "en".
    public init(transcriptionLanguage: String) {
        self = transcriptionLanguage == "en" ? .english : .japanese
    }
}
