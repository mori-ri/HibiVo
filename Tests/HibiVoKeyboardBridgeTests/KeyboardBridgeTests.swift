import Foundation
import Testing

@testable import HibiVoKeyboardBridge

@Suite struct KeyboardBridgeTests {
    private func temporaryStore() -> BridgeStore {
        BridgeStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    }

    @Test func stateRoundTripsThroughTheSharedFile() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(store.state() == nil)

        var state = BridgeState(phase: .recording, partial: "こんにちは")
        state.result = BridgeResult(text: "前の結果")
        state.notice = BridgeNotice(message: "ネットワークに接続できません")
        try store.write(state)

        #expect(store.state() == state)
    }

    @Test func reportRoundTripsThroughTheSharedFile() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(store.report() == nil)

        let report = KeyboardReport(lastInserted: UUID())
        try store.write(report)

        #expect(store.report() == report)
    }

    @Test func freshResultIsPending() {
        let result = BridgeResult(text: "こんにちは")
        let state = BridgeState(phase: .ready, result: result)

        #expect(state.pendingResult(lastInserted: nil) == result)
        #expect(state.pendingResult(lastInserted: UUID()) == result)
    }

    @Test func insertedResultIsNotPendingAgain() {
        let result = BridgeResult(text: "こんにちは")
        let state = BridgeState(phase: .ready, result: result)

        #expect(state.pendingResult(lastInserted: result.id) == nil)
    }

    @Test func staleResultIsDropped() {
        let created = Date()
        let state = BridgeState(phase: .ready, result: BridgeResult(text: "こんにちは", createdAt: created))

        let justInTime = created.addingTimeInterval(KeyboardBridge.resultLifetime - 1)
        let tooLate = created.addingTimeInterval(KeyboardBridge.resultLifetime + 1)
        #expect(state.pendingResult(now: justInTime, lastInserted: nil) != nil)
        #expect(state.pendingResult(now: tooLate, lastInserted: nil) == nil)
    }

    @Test func noResultMeansNothingPending() {
        #expect(BridgeState(phase: .ready).pendingResult(lastInserted: nil) == nil)
    }

    @Test func commandRoundTripsThroughTheSharedFile() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(store.command() == nil)

        let command = BridgeCommand(kind: .start)
        try store.write(command)

        #expect(store.command() == command)
    }

    @Test func commandIsHandledOnce() {
        let command = BridgeCommand(kind: .start)

        #expect(command.isCurrent(lastHandled: nil))
        #expect(command.isCurrent(lastHandled: UUID()))
        #expect(!command.isCurrent(lastHandled: command.id))
    }

    @Test func oldCommandIsIgnored() {
        let command = BridgeCommand(kind: .start)
        let later = command.sentAt.addingTimeInterval(KeyboardBridge.commandLifetime + 1)

        #expect(!command.isCurrent(now: later, lastHandled: nil))
    }

    @Test func activationOutlivesOtherCommands() {
        let command = BridgeCommand(kind: .activate)
        let whileOpening = command.sentAt.addingTimeInterval(KeyboardBridge.commandLifetime + 1)
        let tooLate = command.sentAt.addingTimeInterval(KeyboardBridge.activationLifetime + 1)

        #expect(command.isCurrent(now: whileOpening, lastHandled: nil))
        #expect(!command.isCurrent(now: tooLate, lastHandled: nil))
    }

    @Test func freshNoticeIsShownOnce() {
        let notice = BridgeNotice(message: "ネットワークに接続できません")
        let state = BridgeState(phase: .ready, notice: notice)

        #expect(state.pendingNotice(lastShown: nil) == notice)
        #expect(state.pendingNotice(lastShown: notice.id) == nil)
        let tooLate = notice.createdAt.addingTimeInterval(KeyboardBridge.noticeLifetime + 1)
        #expect(state.pendingNotice(now: tooLate, lastShown: nil) == nil)
    }
}
