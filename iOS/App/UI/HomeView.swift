import SwiftUI
import UIKit

struct HomeView: View {
    let environment: MobileEnvironment

    @Environment(\.scenePhase) private var scenePhase
    @State private var permission = MicrophoneSession.permission
    @State private var keyboardIsSetUp = false
    @State private var trial = ""

    private var dictation: MobileDictationController { environment.dictation }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    session
                }
                Section {
                    microphoneStep
                    keyboardStep
                } header: {
                    Text("セットアップ")
                } footer: {
                    Text(
                        "フルアクセスは、キーボードがこのアプリとやり取りするために必要です。キーボードは入力欄の内容を読み取らず、ネットワークにも接続しません。"
                    )
                }
                Section {
                    TextField("ここをタップして、キーボードを HibiVo に切り替えてください", text: $trial, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("試す")
                }
            }
            .navigationTitle("HibiVo")
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: dictation.phase)
        }
        .task { refresh() }
        .onChange(of: scenePhase) { refresh() }
    }

    /// Both can change while the app is in the background (in Settings).
    private func refresh() {
        permission = MicrophoneSession.permission
        keyboardIsSetUp = environment.bridge?.report() != nil
    }

    // MARK: - Session

    @ViewBuilder
    private var session: some View {
        if dictation.showsReturnHint {
            Label {
                Text("準備できました。画面左上の「◀」をタップするか、画面の下端を右にスワイプして、元のアプリに戻ってください。")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        switch dictation.phase {
        case .inactive:
            VStack(alignment: .leading, spacing: 6) {
                Text("マイクはオフです").font(.headline)
                Text("キーボードのマイクを押すと、このアプリが開いてマイクがオンになります。ここでオンにしておくこともできます。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button("マイクをオンにする") {
                Task {
                    await dictation.startSession()
                    refresh()
                }
            }
        case .ready:
            VStack(alignment: .leading, spacing: 6) {
                Label("マイクはオンです", systemImage: "mic.fill").font(.headline)
                Text("入力したいアプリで HibiVo キーボードのマイクを押して話してください。\(environment.settings.standbyMinutes) 分間使わないと自動でオフになります。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button("マイクをオフにする", role: .destructive) { dictation.endSession() }
        case .recording:
            HStack(spacing: 12) {
                LevelBars(level: dictation.audioLevel, colorful: environment.settings.cleanupEnabled)
                Text(dictation.partial.isEmpty ? String(localized: "聞いています…") : dictation.partial)
                    .lineLimit(3)
                    .truncationMode(.head)
            }
        case .processing:
            HStack(spacing: 12) {
                ProgressView()
                Text("入力しています…")
            }
        }
        if let error = dictation.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.subheadline)
        }
    }

    // MARK: - Setup

    private var microphoneStep: some View {
        SetupStep(done: permission == .granted, title: "マイクへのアクセスを許可する") {
            if permission == .undetermined {
                Button("許可する") {
                    Task {
                        _ = await MicrophoneSession.requestPermission()
                        refresh()
                    }
                }
            } else if permission == .denied {
                Text("「設定」でこのアプリのマイクをオンにしてください。")
                Button("設定を開く", action: openSettings)
            }
        }
    }

    private var keyboardStep: some View {
        SetupStep(done: keyboardIsSetUp, title: "キーボードを追加して、フルアクセスを許可する") {
            if !keyboardIsSetUp {
                Text("「設定」›「キーボード」で HibiVo をオンにし、続けて「フルアクセスを許可」をオンにします。そのあと、文字を入力する画面で 🌐 を押して HibiVo に切り替えてください。")
                Button("設定を開く", action: openSettings)
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct SetupStep<Detail: View>: View {
    var done: Bool
    var title: LocalizedStringKey
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                detail
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
            }
        }
    }
}

/// The microphone level while recording. In the logo's colours when AI cleanup is on, plain when it is
/// off, like the HUD on the Mac (see DESIGN.md).
private struct LevelBars: View {
    var level: Float
    var colorful: Bool

    private static let weights: [CGFloat] = [0.5, 0.8, 1, 0.7, 0.45]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Self.weights.indices, id: \.self) { index in
                Capsule()
                    .frame(width: 3, height: 4 + 18 * Self.weights[index] * min(1, CGFloat(level) * 8))
            }
        }
        .frame(height: 24)
        .foregroundStyle(
            colorful
                ? AnyShapeStyle(
                    LinearGradient(
                        colors: [Theme.glowBlue, Theme.glowMagenta, Theme.glowOrange], startPoint: .leading,
                        endPoint: .trailing))
                : AnyShapeStyle(.primary)
        )
        .animation(.easeOut(duration: 0.1), value: level)
    }
}
