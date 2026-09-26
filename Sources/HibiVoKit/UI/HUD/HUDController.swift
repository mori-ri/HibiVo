import AppKit
import SwiftUI

/// A small non-activating floating panel that never steals focus or mouse clicks.
@MainActor
public final class HUDController {
    private let state: AppState
    private let panel: NSPanel
    private let hostingView: NSHostingView<HUDView>

    private let settings: SettingsStore

    public init(state: AppState, settings: SettingsStore) {
        self.state = state
        self.settings = settings
        hostingView = NSHostingView(rootView: HUDView(state: state, settings: settings))
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = hostingView
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = state.phase
            _ = state.partialTranscript
            _ = settings.showLiveTranscript
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        switch state.phase {
        case .idle:
            panel.orderOut(nil)
        case .recording, .processing, .error:
            layout()
            panel.orderFrontRegardless()
        }
    }

    private func layout() {
        let size = hostingView.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 48)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
