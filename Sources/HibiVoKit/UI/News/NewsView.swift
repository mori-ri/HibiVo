import SwiftUI

/// What's new: a download button when a newer version is out, then the release notes from GitHub, newest first.
struct NewsView: View {
    let env: AppEnvironment
    /// Set once the page has asked for the notes, so "no notes" isn't shown before the first answer.
    @State private var requested = false

    var body: some View {
        let updates = env.updates
        SettingsPage {
            if let version = updates.availableVersion {
                SettingsSection {
                    LabeledRow("新しいバージョン \(version) があります") {
                        Button("ダウンロード") { ProjectLinks.open(ProjectLinks.latestDownload) }
                            .buttonStyle(.borderedProminent)
                    }
                    NoteRow(
                        "HibiVo を終了してから、ダウンロードしたディスクイメージを開き、HibiVo.app を「アプリケーション」フォルダにドラッグして置き換えます。設定や辞書、履歴は引き継がれます。"
                    )
                }
            }
            if updates.notes.isEmpty {
                SettingsSection { status }
            }
            ForEach(updates.notes) { note in
                ReleaseNoteSection(note: note, current: updates.currentVersion)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("GitHub のリリースノートを表示しています。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("すべてのリリースを GitHub で見る") { ProjectLinks.open(ProjectLinks.releases) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 4)
        }
        .task {
            // The setting is about asking GitHub at all; with it off, the page waits for the button.
            guard updates.notes.isEmpty, env.settings.checksForUpdates else { return }
            requested = true
            // The launch check may still be running; its answer fills the page.
            if !updates.isLoading { await updates.loadNotes() }
        }
        // Whatever the page shows counts as read, including notes that arrive while it is open.
        .task(id: updates.notes.first?.id) {
            if updates.hasUnreadNotes(lastSeen: env.settings.lastSeenReleaseNotes) {
                env.settings.lastSeenReleaseNotes = updates.notes.first?.version.text
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        let updates = env.updates
        if updates.isLoading || (!requested && env.settings.checksForUpdates) {
            SettingsRow {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("読み込み中…").foregroundStyle(.secondary)
                }
            }
        } else if updates.loadFailed {
            LabeledRow("お知らせを読み込めませんでした。インターネットへの接続を確認してください。") {
                Button("再試行") { Task { await load() } }
            }
        } else if !requested {
            LabeledRow("新しいバージョンの確認がオフのため、お知らせを読み込んでいません。") {
                Button("読み込む") { Task { await load() } }
            }
        } else {
            NoteRow("お知らせはまだありません。")
        }
    }

    private func load() async {
        requested = true
        await env.updates.loadNotes()
    }
}

/// One release: its version and date above a card of its notes.
private struct ReleaseNoteSection: View {
    let note: ReleaseNote
    let current: AppVersion?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("バージョン \(note.version.text)")
                    .font(.system(size: 13, weight: .semibold))
                if let current, note.version == current {
                    VersionBadge(title: "使用中", isProminent: false)
                } else if let current, note.version > current {
                    VersionBadge(title: "新しいバージョン", isProminent: true)
                }
                Spacer()
                if let date = note.publishedAt {
                    Text(date, format: .dateTime.year().month().day())
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            SettingsSection {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 6) {
                        if note.blocks.isEmpty {
                            Text("このバージョンの説明はありません。").foregroundStyle(.secondary)
                        }
                        ForEach(Array(note.blocks.enumerated()), id: \.offset) { index, block in
                            ReleaseNoteBlockView(block: block, isFirst: index == 0)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct ReleaseNoteBlockView: View {
    let block: ReleaseNoteBlock
    let isFirst: Bool

    var body: some View {
        switch block {
        case .heading(let text):
            Text(ReleaseNotes.inline(text))
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, isFirst ? 0 : 8)
        case .paragraph(let text):
            Text(ReleaseNotes.inline(text))
                .fixedSize(horizontal: false, vertical: true)
        case .item(let marker, let text, let level):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: marker).foregroundStyle(.secondary)
                Text(ReleaseNotes.inline(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(level) * 16)
        }
    }
}

/// "In use" or "New" next to a version.
private struct VersionBadge: View {
    let title: LocalizedStringKey
    let isProminent: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .background(isProminent ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.selection), in: Capsule())
            .overlay(Capsule().strokeBorder(isProminent ? Color.clear : Theme.cardStroke, lineWidth: 1))
    }
}
