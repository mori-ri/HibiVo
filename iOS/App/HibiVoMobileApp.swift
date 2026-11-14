import SwiftUI

@main
struct HibiVoMobileApp: App {
    @State private var environment = MobileEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
                .onOpenURL { url in
                    guard url.absoluteString == KeyboardBridge.sessionURL else { return }
                    Task { await environment.dictation.openedFromKeyboard() }
                }
                .task { await environment.prepareSpeechModel() }
        }
    }
}

struct RootView: View {
    let environment: MobileEnvironment

    var body: some View {
        TabView {
            Tab("ホーム", systemImage: "house") {
                HomeView(environment: environment)
            }
            Tab("辞書", systemImage: "character.book.closed") {
                VocabularyView(store: environment.vocabulary)
            }
            Tab("履歴", systemImage: "clock") {
                HistoryView(store: environment.history)
            }
            Tab("設定", systemImage: "gearshape") {
                SettingsView(environment: environment)
            }
        }
    }
}
