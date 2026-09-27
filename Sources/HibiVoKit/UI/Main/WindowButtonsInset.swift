import AppKit
import SwiftUI

/// Moves the traffic lights right and down so they sit inside the floating sidebar panel instead
/// of on its rounded corner. AppKit lays the buttons out again on resize, key changes and
/// full-screen transitions, so the offset is re-applied from their default positions each time.
struct WindowButtonsInset: NSViewRepresentable {
    var dx: CGFloat
    var dy: CGFloat

    func makeNSView(context: Context) -> TrackingView {
        TrackingView(offset: CGSize(width: dx, height: dy))
    }

    func updateNSView(_ view: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        private let offset: CGSize
        private var defaults: [NSWindow.ButtonType: NSPoint] = [:]
        private var applied: [NSWindow.ButtonType: NSPoint] = [:]
        private var observers: [NSObjectProtocol] = []

        private static let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        init(offset: CGSize) {
            self.offset = offset
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }

            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            for name in names {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated { self?.scheduleApply() }
                    })
            }
            if let titlebar = window.standardWindowButton(.closeButton)?.superview {
                titlebar.postsFrameChangedNotifications = true
                observers.append(
                    NotificationCenter.default.addObserver(
                        forName: NSView.frameDidChangeNotification, object: titlebar, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.scheduleApply() }
                    })
            }
            apply()
        }

        /// AppKit may still be mid-layout when the notification fires.
        private func scheduleApply() {
            apply()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.apply() }
            }
        }

        private func apply() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            for type in Self.types {
                guard let button = window.standardWindowButton(type) else { continue }
                let origin = button.frame.origin
                // A position other than the one we set means AppKit laid the button out afresh.
                if applied[type] != origin { defaults[type] = origin }
                guard let base = defaults[type] else { continue }
                let target = NSPoint(x: base.x + offset.width, y: base.y - offset.height)
                if origin != target { button.setFrameOrigin(target) }
                applied[type] = target
            }
        }
    }
}
