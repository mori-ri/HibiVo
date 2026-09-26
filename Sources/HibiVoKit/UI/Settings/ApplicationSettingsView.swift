import AppKit
import SwiftUI

struct ApplicationSettingsView: View {
    let settings: SettingsStore
    @State private var newApp: String? = nil

    private struct Row: Identifiable {
        var bundleID: String
        var name: String
        var mode: CleanupMode
        var isCustom: Bool
        var id: String { bundleID }
    }

    var body: some View {
        Form {
            Section {
                ForEach(rows) { row in
                    Picker(selection: modeBinding(row)) {
                        ForEach(CleanupMode.allCases) { Text($0.displayName).tag($0) }
                    } label: {
                        HStack {
                            Text(row.name)
                            if row.isCustom { Text("変更済み").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .contextMenu {
                        if row.isCustom {
                            Button("既定に戻す") { settings.setMode(nil, bundleID: row.bundleID, name: row.name) }
                        }
                    }
                }
            } header: {
                Text("アプリごとの整形モード")
            } footer: {
                FormFooter("一覧にないアプリは「既定のモード」（AI 整形ページ）を使います。右クリックで既定に戻せます。")
            }
            Section("アプリを追加") {
                Picker("起動中のアプリ", selection: $newApp) {
                    Text("選択…").tag(String?.none)
                    ForEach(runningApps, id: \.bundleID) { Text($0.name).tag(Optional($0.bundleID)) }
                }
                .onChange(of: newApp) { _, bundleID in
                    guard let bundleID, let app = runningApps.first(where: { $0.bundleID == bundleID }) else { return }
                    settings.setMode(settings.defaultCleanupMode, bundleID: app.bundleID, name: app.name)
                    newApp = nil
                }
            }
        }
        .pageForm()
    }

    private var rows: [Row] {
        var result: [String: Row] = [:]
        for (bundleID, value) in AppModeRules.builtIn {
            result[bundleID] = Row(bundleID: bundleID, name: value.name, mode: value.mode, isCustom: false)
        }
        for override in settings.appModeOverrides {
            result[override.bundleID] = Row(
                bundleID: override.bundleID, name: override.name, mode: override.mode, isCustom: true)
        }
        return result.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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

    private func modeBinding(_ row: Row) -> Binding<CleanupMode> {
        Binding(
            get: { row.mode },
            set: { settings.setMode($0, bundleID: row.bundleID, name: row.name) })
    }
}
