import AppKit
import SwiftUI

/// A small non-activating floating panel that never steals focus. It takes clicks only while
/// recording, to toggle AI cleanup, while it shows learned words, to undo them, and during a meeting,
/// for its notes and stop buttons; otherwise clicks pass through to the app underneath.
@MainActor
public final class HUDController {
    private let state: AppState
    private let panel: NSPanel
    private let hostingView: HUDHostingView

    private let settings: SettingsStore
    private let model = HUDModel()

    public init(
        state: AppState, settings: SettingsStore, onClick: @escaping @MainActor () -> Void,
        onHover: @escaping @MainActor (Bool) -> Void = { _ in },
        onStopMeeting: @escaping @MainActor () -> Void = {},
        onToggleMeetingNotes: @escaping @MainActor () -> Void = {}
    ) {
        self.state = state
        self.settings = settings
        let model = model
        let actions = HUDActions(
            stopMeeting: { if model.confirmStop() { onStopMeeting() } },
            toggleMeetingNotes: onToggleMeetingNotes)
        hostingView = HUDHostingView(
            rootView: HUDView(state: state, settings: settings, model: model, actions: actions))
        hostingView.onClick = onClick
        hostingView.onHover = { hovering in
            // Moving away cancels an armed stop, so a later stray click can't end the meeting.
            if !hovering { model.reset() }
            onHover(hovering)
        }
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
            _ = state.meetingReconnecting
            _ = state.learnedVocabulary
            _ = settings.showLiveTranscript
            _ = model.stopArmed
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        if state.phase != .meeting { model.reset() }
        switch state.phase {
        case .idle where !state.learnedVocabulary.isEmpty:
            panel.ignoresMouseEvents = false
            layout()
            panel.orderFrontRegardless()
        case .idle:
            panel.orderOut(nil)
        case .recording, .processing, .meeting, .error:
            panel.ignoresMouseEvents = state.phase != .recording && state.phase != .meeting
            hostingView.hasButtons = state.phase == .meeting
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
    var onHover: (@MainActor (Bool) -> Void)?
    /// Lets SwiftUI handle the click, for the meeting HUD's buttons.
    var hasButtons = false
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // `.activeAlways`: the panel is never key, and the app is usually not active.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if hasButtons {
            super.mouseDown(with: event)
        } else {
            onClick?()
        }
    }
}
