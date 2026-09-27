import AppKit
import SwiftUI

/// A small non-activating floating panel that never steals focus. It takes clicks only while
/// recording, to toggle AI cleanup; otherwise clicks pass through to the app underneath.
@MainActor
public final class HUDController {
    private let state: AppState
    private let panel: NSPanel
    private let hostingView: HUDHostingView

    private let settings: SettingsStore

    public init(state: AppState, settings: SettingsStore, onClick: @escaping @MainActor () -> Void) {
        self.state = state
        self.settings = settings
        hostingView = HUDHostingView(rootView: HUDView(state: state, settings: settings))
        hostingView.onClick = onClick
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
            panel.ignoresMouseEvents = state.phase != .recording
            layout()
            panel.orderFrontRegardless()
        }
    }

    private func layout() {
        let size = hostingView.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// Handles the click itself rather than through SwiftUI: the panel never becomes key, so the
/// first click has to be accepted and must not be swallowed as a window-activation click.
private final class HUDHostingView: NSHostingView<HUDView> {
    var onClick: (@MainActor () -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
