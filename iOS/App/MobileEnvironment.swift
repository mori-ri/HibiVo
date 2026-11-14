import Foundation
import Observation

/// The iOS app's composition root: every service is created here and handed its dependencies.
@MainActor
@Observable
final class MobileEnvironment {
    let settings: MobileSettings
    let secrets: any SecretStore
    let transcriptionProviders: [any TranscriptionProvider]
    let vocabulary: VocabularyStore
    let history: HistoryStore
    let bridge: BridgeStore?
    let dictation: MobileDictationController

    /// Where the on-device speech model stands; nil when another provider is selected.
    private(set) var speechModel: AppleSpeechProvider.ModelStatus?

    init() {
        var providers: [any TranscriptionProvider] = [SonioxProvider(), GeminiLiveProvider()]
        if AppleSpeechProvider.isSupported { providers.insert(AppleSpeechProvider(), at: 0) }
        let settings = MobileSettings(defaultTranscriptionProviderID: providers[0].id)
        let secrets = KeychainService()
        let vocabulary = VocabularyStore()
        let history = HistoryStore()
        let bridge = BridgeStore.appGroup()
        transcriptionProviders = providers
        self.settings = settings
        self.secrets = secrets
        self.vocabulary = vocabulary
        self.history = history
        self.bridge = bridge
        dictation = MobileDictationController(
            settings: settings, secrets: secrets, transcriptionProviders: providers, vocabulary: vocabulary,
            history: history, microphone: MicrophoneSession(), store: bridge)
    }

    /// Downloads the on-device speech model ahead of the first dictation. Call at launch and whenever
    /// the provider or the language changes.
    func prepareSpeechModel() async {
        guard dictation.transcriptionProvider is AppleSpeechProvider else {
            speechModel = nil
            return
        }
        let language = settings.language
        speechModel = .downloading
        let status = await AppleSpeechProvider.prepareModel(language: language)
        // The setting may have changed while the model was downloading; that change started its own call.
        if language == settings.language, dictation.transcriptionProvider is AppleSpeechProvider {
            speechModel = status
        }
    }
}
