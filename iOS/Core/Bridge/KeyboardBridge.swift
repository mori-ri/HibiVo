import Foundation

/// How the keyboard extension and the app talk to each other.
///
/// iOS doesn't let a keyboard extension use the microphone, so the app records and transcribes while it
/// runs in the background, and the keyboard only sends commands and inserts the result.
///
/// Both sides write small files into the shared App Group container and post a Darwin notification to
/// say "look again". The notifications carry no data and any app can post them, so nothing is ever done
/// on a notification alone: what to do is read from the container, which only HibiVo can write.
enum KeyboardBridge {
    static let appGroup = "group.io.github.mori-ri.hibivo.ios"
    /// Opens the app from the keyboard to start a dictation session.
    static let sessionURL = "hibivo://dictate"
    /// Posted by the app after every write of the state file.
    static let stateChanged = "io.github.mori-ri.hibivo.ios.bridge.state"
    /// Posted by the keyboard after every write of the command file.
    static let commandSent = "io.github.mori-ri.hibivo.ios.bridge.command"

    /// How long the keyboard waits for the app to answer a command before treating it as not running.
    static let replyTimeout: Duration = .milliseconds(1500)
    /// A command older than this is ignored: the app may only get to it much later (it was suspended).
    static let commandLifetime: TimeInterval = 5
    /// Opening the app takes longer than a notification, so its command stays good for longer.
    static let activationLifetime: TimeInterval = 30
    /// A result older than this is not inserted: the caret has likely moved on to something else.
    static let resultLifetime: TimeInterval = 60
    /// An error older than this is about something the user has moved on from.
    static let noticeLifetime: TimeInterval = 10
}

/// What the keyboard asks of the app.
struct BridgeCommand: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// "Are you there?" The app answers by publishing its state again.
        case ping
        /// Sent just before opening the app through `KeyboardBridge.sessionURL`: turn the microphone on.
        case activate
        case start
        case stop
        case cancel
    }

    var id = UUID()
    var kind: Kind
    var sentAt = Date()

    /// Whether the app should still act on this command.
    /// - Parameter lastHandled: The command the app handled last, so a notification posted twice (or by
    ///   another app) doesn't run it again.
    func isCurrent(now: Date = Date(), lastHandled: UUID?) -> Bool {
        let lifetime = kind == .activate ? KeyboardBridge.activationLifetime : KeyboardBridge.commandLifetime
        let age = now.timeIntervalSince(sentAt)
        return id != lastHandled && age < lifetime && age > -lifetime
    }
}

/// What the app tells the keyboard.
struct BridgeState: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        /// No dictation session: the microphone is off and the app may not be running.
        case inactive
        /// The app is running in the background with the microphone ready.
        case ready
        case recording
        case processing
    }

    var phase: Phase = .inactive
    /// Live transcript while recording.
    var partial = ""
    /// The text of the last finished dictation, for the keyboard to insert.
    var result: BridgeResult?
    /// Something to tell the user (an error), already phrased and localized by the app.
    var notice: BridgeNotice?
    var updatedAt = Date()

    /// The result the keyboard should insert now, if any.
    /// - Parameter lastInserted: The result this keyboard already inserted.
    func pendingResult(now: Date = Date(), lastInserted: UUID?) -> BridgeResult? {
        guard let result, result.id != lastInserted,
            now.timeIntervalSince(result.createdAt) < KeyboardBridge.resultLifetime
        else { return nil }
        return result
    }

    /// The notice the keyboard should show now, if any.
    /// - Parameter lastShown: The notice this keyboard already showed.
    func pendingNotice(now: Date = Date(), lastShown: UUID?) -> BridgeNotice? {
        guard let notice, notice.id != lastShown,
            now.timeIntervalSince(notice.createdAt) < KeyboardBridge.noticeLifetime
        else { return nil }
        return notice
    }
}

struct BridgeResult: Codable, Equatable, Sendable {
    var id = UUID()
    var text: String
    var createdAt = Date()
}

struct BridgeNotice: Codable, Equatable, Sendable {
    var id = UUID()
    var message: String
    var createdAt = Date()
}

/// What the keyboard leaves for the app. Writing it needs Full Access, so its presence also tells the
/// app that the keyboard is installed with Full Access.
struct KeyboardReport: Codable, Equatable, Sendable {
    /// The last result the keyboard inserted, so a keyboard that is shown again doesn't insert it twice.
    var lastInserted: UUID?
    var seenAt = Date()
}

/// The files both sides share. The app writes the state; the keyboard writes commands and its report.
struct BridgeStore: Sendable {
    let directory: URL

    /// nil when the App Group isn't set up (a build signed without the entitlement).
    static func appGroup() -> BridgeStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardBridge.appGroup).map {
            BridgeStore(directory: $0.appending(path: "Bridge"))
        }
    }

    func state() -> BridgeState? { read("state.json") }

    func write(_ state: BridgeState) throws { try write(state, to: "state.json") }

    func command() -> BridgeCommand? { read("command.json") }

    func write(_ command: BridgeCommand) throws { try write(command, to: "command.json") }

    func report() -> KeyboardReport? { read("keyboard.json") }

    func write(_ report: KeyboardReport) throws { try write(report, to: "keyboard.json") }

    private func read<Value: Decodable>(_ name: String) -> Value? {
        guard let data = try? Data(contentsOf: directory.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func write(_ value: some Encodable, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appending(path: name), options: [.atomic])
    }
}

/// Darwin notifications cross process boundaries, which is all the two sides have in common.
enum DarwinNotification {
    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }
}

/// Calls `handler` for each Darwin notification called `name`, until released.
/// Create it on the main thread: notifications are delivered to the run loop it was created on.
final class DarwinNotificationObserver {
    private let name: String
    private let handler: @MainActor () -> Void

    init(name: String, handler: @escaping @MainActor () -> Void) {
        self.name = name
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                // The pointer is copied to a Sendable value before entering the main actor.
                let address = UInt(bitPattern: observer)
                MainActor.assumeIsolated {
                    guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
                    Unmanaged<DarwinNotificationObserver>.fromOpaque(pointer).takeUnretainedValue().handler()
                }
            }, name as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString), nil)
    }
}
