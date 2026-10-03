import AppKit
import SwiftUI

struct ApplicationSettingsView: View {
    let settings: SettingsStore
    @State private var newApp: String? = nil

    var body: some View {
        SettingsPage {
            SettingsSection(
                title: "アプリごとの整形モード",
                footer: "一覧にないアプリは、AI 整形の「既定のモード」を使います。モードごとの違いと出力例は、AI 整形の「既定のモード」で確認できます。"
            ) {
                if rows.isEmpty {
                    Text("まだありません。下の「アプリを追加」から追加できます。").foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    LabeledRow {
                        Text(row.name)
                    } control: {
                        HStack {
                            Picker(row.name, selection: modeBinding(row)) {
                                ForEach(CleanupMode.allCases) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Button {
                                settings.setMode(nil, bundleID: row.bundleID, name: row.name)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("一覧から削除")
                            .accessibilityLabel("\(row.name) を削除")
                        }
                    }
                }
            }
            SettingsSection(title: "アプリを追加") {
                PickerRow("起動中のアプリ", selection: $newApp) {
                    Text("選択…").tag(String?.none)
                    ForEach(addableApps, id: \.bundleID) { Text($0.name).tag(Optional($0.bundleID)) }
                }
                .onChange(of: newApp) { _, bundleID in
                    guard let bundleID, let app = addableApps.first(where: { $0.bundleID == bundleID }) else { return }
                    settings.setMode(settings.defaultCleanupMode, bundleID: app.bundleID, name: app.name)
                    newApp = nil
                }
            }
        }
    }

    private var rows: [AppModeOverride] {
        settings.appModeOverrides.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Running apps that aren't in the list yet.
    private var addableApps: [(bundleID: String, name: String)] {
        let listed = Set(settings.appModeOverrides.map { $0.bundleID.lowercased() })
        return runningApps.filter { !listed.contains($0.bundleID.lowercased()) }
    }

    private var runningApps: [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func modeBinding(_ row: AppModeOverride) -> Binding<CleanupMode> {
        Binding(
            get: { row.mode },
            set: { settings.setMode($0, bundleID: row.bundleID, name: row.name) })
    }
}
