import SwiftUI

public enum MainSection: String, CaseIterable, Identifiable, Sendable {
    case history
    case usage
    case general
    case transcription
    case cleanup
    case meeting
    case vocabulary
    case applications

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .history: "履歴"
        case .usage: "利用状況"
        case .general: "一般"
        case .transcription: "文字起こし"
        case .cleanup: "AI 整形"
        case .meeting: "ミーティング"
        case .vocabulary: "辞書"
        case .applications: "アプリ"
        }
    }

    var subtitle: String {
        switch self {
        case .history: "これまでに入力したテキスト"
        case .usage: "利用回数、話した時間、API 料金の目安"
        case .general: "起動、ホットキー、マイク、権限"
        case .transcription: "音声をテキストにするサービス"
        case .cleanup: "LLM で文章を読みやすく整える"
        case .meeting: "会議の文字起こしと議事録"
        case .vocabulary: "固有名詞や専門用語の表記"
        case .applications: "アプリごとの整形モード"
        }
    }

    var symbol: String {
        switch self {
        case .history: "clock"
        case .usage: "chart.bar"
        case .general: "gearshape"
        case .transcription: "waveform"
        case .cleanup: "sparkles"
        case .meeting: "person.2.wave.2"
        case .vocabulary: "character.book.closed"
        case .applications: "square.grid.2x2"
        }
    }

    static let settings: [MainSection] = [.general, .transcription, .cleanup, .meeting, .vocabulary, .applications]
}

/// The single app window: sidebar navigation on the left, the selected page on the right.
public struct MainWindowView: View {
    let env: AppEnvironment

    public init(env: AppEnvironment) {
        self.env = env
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Floating glass sidebar; the traffic lights sit inside its top edge.
            Sidebar(env: env)
                .frame(width: 212)
                .glassPanel(cornerRadius: 18)
                .padding(8)
            page(env.state.mainSection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(GlassBackdrop())
        .background(WindowButtonsInset(dx: 8, dy: 6))
        .ignoresSafeArea()
        .frame(minWidth: 780, minHeight: 520)
    }

    @ViewBuilder
    private func page(_ section: MainSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(section: section) {
                switch section {
                case .history: HistoryHeaderActions(history: env.history)
                case .usage: UsageHeaderActions(usage: env.usage)
                default: EmptyView()
                }
            }
            switch section {
            case .history: HistoryView(env: env)
            case .usage: UsageView(env: env)
            case .general: GeneralSettingsView(env: env)
            case .transcription: TranscriptionSettingsView(env: env)
            case .cleanup: CleanupSettingsView(env: env)
            case .meeting: MeetingSettingsView(env: env)
            case .vocabulary: VocabularySettingsView(store: env.vocabulary, settings: env.settings)
            case .applications: ApplicationSettingsView(settings: env.settings)
            }
        }
        // Clears per-page @State (e.g. the history selection) when switching pages.
        .id(section)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    let env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppLogo(height: 26)
                Text("HibiVo")
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.2)
            }
            .padding(.horizontal, 16)
            // The hidden title bar puts the traffic lights over the top of the sidebar.
            .padding(.top, 44)
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 2) {
                item(.history)
                item(.usage)
                Text("設定")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 20)
                    .padding(.bottom, 6)
                ForEach(MainSection.settings) { item($0) }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 2) {
                SidebarLink(title: "フィードバック・要望", symbol: "bubble.left", url: ProjectLinks.newFeedback)
                SidebarLink(
                    title: "GitHub リポジトリ", symbol: "chevron.left.forwardslash.chevron.right",
                    url: ProjectLinks.repository)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 4) {
                Label("\(env.settings.hotkey.displayName) を押して話す", systemImage: "mic")
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text("バージョン \(version)").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func item(_ section: MainSection) -> some View {
        SidebarItem(section: section, isSelected: env.state.mainSection == section) {
            env.state.mainSection = section
        }
    }
}

private struct SidebarItem: View {
    let section: MainSection
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                if isSelected {
                    shape.fill(Theme.selection)
                        .overlay(shape.strokeBorder(Theme.rim, lineWidth: 0.5))
                        .shadow(color: Theme.selectionShadow, radius: 3, y: 1)
                } else if isHovered {
                    shape.fill(Theme.hover)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Opens a project page in the browser; quieter than `SidebarItem` so it doesn't read as a page.
private struct SidebarLink: View {
    let title: String
    let symbol: String
    let url: URL
    @State private var isHovered = false

    var body: some View {
        Button {
            ProjectLinks.open(url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(isHovered ? 1 : 0)
            }
            .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                if isHovered { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.hover) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(url.absoluteString)
    }
}

// MARK: - Page header

private struct PageHeader<Actions: View>: View {
    let section: MainSection
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(section.title)
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.3)
                Text(section.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
        .padding(.bottom, 8)
    }
}
