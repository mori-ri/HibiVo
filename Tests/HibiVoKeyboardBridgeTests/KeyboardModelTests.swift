import Foundation
import Testing

@testable import HibiVoKeyboardBridge

@MainActor
@Suite struct KeyboardModelTests {
    /// Records what the keyboard did to the outside world.
    @MainActor
    final class HostSpy {
        var inserted: [String] = []
        var opened = 0
        var hasFullAccess = true

        var host: KeyboardModel.Host {
            KeyboardModel.Host(
                insert: { self.inserted.append($0) }, openApp: { self.opened += 1 },
                hasFullAccess: { self.hasFullAccess })
        }
    }

    private let store = BridgeStore(
        directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    private let spy = HostSpy()

    private func makeModel() -> KeyboardModel {
        KeyboardModel(store: store, host: spy.host, replyWait: .milliseconds(20))
    }

    /// Stands in for the app: writes the state and tells the model, as the Darwin notification would.
    private func publish(_ state: BridgeState, to model: KeyboardModel) throws {
        try store.write(state)
        model.stateChanged()
    }

    @Test func withoutFullAccessNothingIsSent() {
        spy.hasFullAccess = false
        let model = makeModel()
        model.appear()
        model.micTapped()

        #expect(!model.hasFullAccess)
        #expect(!model.isChecking)
        #expect(spy.opened == 0)
        #expect(store.report() == nil)
        #expect(store.command() == nil)
    }

    @Test func appearingLeavesAReportForTheApp() {
        let model = makeModel()
        model.appear()

        #expect(store.report() != nil)
        #expect(store.command()?.kind == .ping)
        #expect(model.isChecking)
    }

    @Test func leftoverStateIsIgnoredWhenTheAppDoesNotAnswer() async throws {
        try store.write(BridgeState(phase: .ready))
        let model = makeModel()
        model.appear()
        await model.waitForReply()

        #expect(model.phase == .inactive)
        #expect(!model.isChecking)
    }

    @Test func tappingWhileInactiveOpensTheApp() async {
        let model = makeModel()
        model.appear()
        await model.waitForReply()
        model.micTapped()

        #expect(spy.opened == 1)
        #expect(store.command()?.kind == .activate)
    }

    @Test func answerFromTheAppSetsThePhase() async throws {
        let model = makeModel()
        model.appear()
        try publish(BridgeState(phase: .ready), to: model)
        await model.waitForReply()

        #expect(model.phase == .ready)
        #expect(!model.isChecking)
        model.micTapped()
        #expect(spy.opened == 0)
        #expect(store.command()?.kind == .start)
    }

    @Test func tappingWhileRecordingStops() throws {
        let model = makeModel()
        model.appear()
        try publish(BridgeState(phase: .recording), to: model)
        model.micTapped()

        #expect(store.command()?.kind == .stop)
    }

    @Test func cancelIsSentOnlyWhileBusy() throws {
        let model = makeModel()
        model.appear()
        try publish(BridgeState(phase: .ready), to: model)
        model.cancelTapped()
        #expect(store.command()?.kind == .ping)

        try publish(BridgeState(phase: .processing), to: model)
        model.cancelTapped()
        #expect(store.command()?.kind == .cancel)
    }

    @Test func partialIsShownOnlyWhileRecording() throws {
        let model = makeModel()
        model.appear()
        try publish(BridgeState(phase: .recording, partial: "こんにち"), to: model)
        #expect(model.partial == "こんにち")

        try publish(BridgeState(phase: .processing, partial: "こんにちは"), to: model)
        #expect(model.partial.isEmpty)
    }

    @Test func resultIsInsertedOnce() throws {
        let model = makeModel()
        model.appear()
        let state = BridgeState(phase: .ready, result: BridgeResult(text: "こんにちは"))
        try publish(state, to: model)
        try publish(state, to: model)

        #expect(spy.inserted == ["こんにちは"])
        #expect(store.report()?.lastInserted == state.result?.id)
    }

    @Test func resultInsertedByAnEarlierKeyboardIsNotInsertedAgain() throws {
        let state = BridgeState(phase: .ready, result: BridgeResult(text: "こんにちは"))
        let first = makeModel()
        first.appear()
        try publish(state, to: first)

        let second = makeModel()
        second.appear()
        try publish(state, to: second)

        #expect(spy.inserted == ["こんにちは"])
    }

    @Test func noticeIsShownOnce() throws {
        let model = makeModel()
        model.appear()
        let state = BridgeState(phase: .ready, notice: BridgeNotice(message: "ネットワークに接続できません"))
        try publish(state, to: model)

        #expect(model.notice == "ネットワークに接続できません")
    }

    @Test func recordingThatGetsNoAnswerFallsBackToInactive() async throws {
        let model = makeModel()
        model.appear()
        try publish(BridgeState(phase: .recording), to: model)
        model.micTapped()
        await model.waitForReply()

        #expect(model.phase == .inactive)
    }
}
