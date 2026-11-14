import Foundation
import Observation

/// What the keyboard shows and does. It owns no audio: it sends commands to the app and inserts the
/// text the app hands back.
@MainActor
@Observable
final class KeyboardModel {
    /// What the keyboard can do to the outside world, supplied by the view controller.
    struct Host {
        var insert: @MainActor (String) -> Void
        var openApp: @MainActor () -> Void
        var hasFullAccess: @MainActor () -> Bool
    }

    private(set) var phase: BridgeState.Phase = .inactive
    private(set) var partial = ""
    private(set) var notice: String?
    private(set) var hasFullAccess = true
    /// True while waiting to hear whether the app is running, so the button doesn't flash "open the app".
    private(set) var isChecking = false

    @ObservationIgnored private let store: BridgeStore?
    @ObservationIgnored private let host: Host
    @ObservationIgnored private let replyWait: Duration
    @ObservationIgnored private var observer: DarwinNotificationObserver?
    @ObservationIgnored private var replyTimeout: Task<Void, Never>?
    @ObservationIgnored private var noticeDismiss: Task<Void, Never>?
    @ObservationIgnored private var lastInserted: UUID?
    @ObservationIgnored private var lastNotice: UUID?

    init(
        store: BridgeStore? = BridgeStore.appGroup(), host: Host,
        replyWait: Duration = KeyboardBridge.replyTimeout
    ) {
        self.store = store
        self.host = host
        self.replyWait = replyWait
        lastInserted = store?.report()?.lastInserted
    }

    /// Call each time the keyboard comes on screen.
    func appear() {
        hasFullAccess = host.hasFullAccess()
        guard hasFullAccess else { return }
        if observer == nil {
            observer = DarwinNotificationObserver(name: KeyboardBridge.stateChanged) { [weak self] in
                self?.stateChanged()
            }
        }
        // Leaving this file behind is how the app knows the keyboard is set up.
        saveReport()
        // The state file may be left over from an app that has since been stopped, so it is only
        // trusted once the app answers.
        isChecking = true
        send(.ping)
    }

    func disappear() {
        observer = nil
        replyTimeout?.cancel()
    }

    func micTapped() {
        guard hasFullAccess else { return }
        switch phase {
        case .inactive:
            // The app turns the microphone on only when it finds this command, not for the URL alone.
            try? store?.write(BridgeCommand(kind: .activate))
            host.openApp()
        case .ready: send(.start)
        case .recording: send(.stop)
        case .processing: break
        }
    }

    func cancelTapped() {
        guard phase == .recording || phase == .processing else { return }
        send(.cancel)
    }

    // MARK: - Private

    /// Every command makes the app publish its state. No answer means it isn't running.
    private func send(_ kind: BridgeCommand.Kind) {
        try? store?.write(BridgeCommand(kind: kind))
        DarwinNotification.post(KeyboardBridge.commandSent)
        replyTimeout?.cancel()
        replyTimeout = Task { [weak self, replyWait] in
            try? await Task.sleep(for: replyWait)
            guard !Task.isCancelled, let self else { return }
            self.isChecking = false
            self.phase = .inactive
            self.partial = ""
        }
    }

    /// Waits until the app has answered the last command or the wait for it ran out. Used by tests.
    func waitForReply() async {
        await replyTimeout?.value
    }

    /// The app published its state, which also proves it is running.
    func stateChanged() {
        replyTimeout?.cancel()
        isChecking = false
        guard let state = store?.state() else { return }
        phase = state.phase
        partial = state.phase == .recording ? state.partial : ""
        if let result = state.pendingResult(lastInserted: lastInserted) {
            lastInserted = result.id
            saveReport()
            host.insert(result.text)
        }
        if let notice = state.pendingNotice(lastShown: lastNotice) {
            lastNotice = notice.id
            show(notice.message)
        }
    }

    private func show(_ message: String) {
        notice = message
        noticeDismiss?.cancel()
        noticeDismiss = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func saveReport() {
        try? store?.write(KeyboardReport(lastInserted: lastInserted))
    }
}
