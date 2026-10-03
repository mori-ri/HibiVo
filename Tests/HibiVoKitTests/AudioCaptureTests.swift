@preconcurrency import AVFoundation
import Testing

@testable import HibiVoKit

@MainActor
private final class TestMicrophoneEngine: MicrophoneEngine {
    let notificationObject: AnyObject = NSObject()
    var failStart = false
    var didStop = false
    var sampleRate: Double?
    var deviceUID: String?
    var continuation: AsyncStream<AudioChunk>.Continuation?

    func start(sampleRate: Double, deviceUID: String?, continuation: AsyncStream<AudioChunk>.Continuation) throws {
        self.sampleRate = sampleRate
        self.deviceUID = deviceUID
        if failStart { throw AudioCaptureError.engineFailed("test") }
        self.continuation = continuation
    }

    func stop() { didStop = true }
    func speak(_ byte: UInt8) { continuation?.yield(AudioChunk(pcm16: Data([byte, 0]), level: 0.1)) }
}

@MainActor
@Suite struct AudioCaptureTests {
    private let center = NotificationCenter()

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    @Test func configurationChangeRebuildsEngineAndKeepsTheStream() async throws {
        var engines: [TestMicrophoneEngine] = []
        let sut = AudioCaptureService(
            makeEngine: {
                let engine = TestMicrophoneEngine()
                engines.append(engine)
                return engine
            }, hasPermission: { true }, notificationCenter: center, recoveryDelays: [.zero])
        let stream = try sut.start(sampleRate: 16_000, deviceUID: "selected-mic")
        var iterator = stream.makeAsyncIterator()
        engines[0].speak(1)
        #expect(await iterator.next()?.pcm16 == Data([1, 0]))
        // Notifications from unrelated engines must not restart this recording.
        center.post(name: .AVAudioEngineConfigurationChange, object: NSObject())
        center.post(name: .AVAudioEngineConfigurationChange, object: engines[0].notificationObject)
        await settle { engines.count == 2 }
        #expect(engines.count == 2)
        #expect(engines[0].didStop)
        let replacement = try #require(engines.last)
        #expect(replacement.sampleRate == 16_000)
        #expect(replacement.deviceUID == "selected-mic")
        replacement.speak(2)
        sut.stop()
        #expect(await iterator.next()?.pcm16 == Data([2, 0]))
        #expect(await iterator.next() == nil)
        #expect(replacement.didStop)
    }

    @Test func transientRestartFailureIsRetried() async throws {
        var engines: [TestMicrophoneEngine] = []
        let sut = AudioCaptureService(
            makeEngine: {
                let engine = TestMicrophoneEngine()
                engine.failStart = engines.count == 1
                engines.append(engine)
                return engine
            }, hasPermission: { true }, notificationCenter: center, recoveryDelays: [.zero, .zero])
        let stream = try sut.start(sampleRate: 16_000, deviceUID: nil)
        center.post(name: .AVAudioEngineConfigurationChange, object: engines[0].notificationObject)
        await settle { engines.count == 3 }
        #expect(engines.count == 3)
        #expect(engines[1].didStop)
        engines.last?.speak(3)
        sut.stop()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.pcm16 == Data([3, 0]))
        #expect(await iterator.next() == nil)
    }

    @Test func exhaustedRecoveryFinishesStream() async throws {
        var engines: [TestMicrophoneEngine] = []
        let sut = AudioCaptureService(
            makeEngine: {
                let engine = TestMicrophoneEngine()
                engine.failStart = !engines.isEmpty
                engines.append(engine)
                return engine
            }, hasPermission: { true }, notificationCenter: center, recoveryDelays: [.zero, .zero])
        let stream = try sut.start(sampleRate: 16_000, deviceUID: nil)
        center.post(name: .AVAudioEngineConfigurationChange, object: engines[0].notificationObject)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(engines.count == 3)
        let allStopped = engines.allSatisfy { $0.didStop }
        #expect(allStopped)
    }

    @Test func stopCancelsAPendingRecovery() async throws {
        var engines: [TestMicrophoneEngine] = []
        let sut = AudioCaptureService(
            makeEngine: {
                let engine = TestMicrophoneEngine()
                engines.append(engine)
                return engine
            }, hasPermission: { true }, notificationCenter: center, recoveryDelays: [.seconds(30)])
        let stream = try sut.start(sampleRate: 16_000, deviceUID: nil)
        center.post(name: .AVAudioEngineConfigurationChange, object: engines[0].notificationObject)
        await settle { engines[0].didStop }
        #expect(engines[0].didStop)
        sut.stop()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        await settle { false }
        #expect(engines.count == 1)
    }

    @Test func queuedOldNotificationCannotRestartANewRecording() async throws {
        var engines: [TestMicrophoneEngine] = []
        let sut = AudioCaptureService(
            makeEngine: {
                let engine = TestMicrophoneEngine()
                engines.append(engine)
                return engine
            }, hasPermission: { true }, notificationCenter: center, recoveryDelays: [.zero])
        let oldStream = try sut.start(sampleRate: 16_000, deviceUID: nil)
        center.post(name: .AVAudioEngineConfigurationChange, object: engines[0].notificationObject)
        let newStream = try sut.start(sampleRate: 24_000, deviceUID: nil)
        engines[1].speak(4)
        sut.stop()
        var oldIterator = oldStream.makeAsyncIterator()
        var newIterator = newStream.makeAsyncIterator()
        #expect(await oldIterator.next() == nil)
        #expect(await newIterator.next()?.pcm16 == Data([4, 0]))
        #expect(await newIterator.next() == nil)
        await settle { false }
        #expect(engines.count == 2)
    }
}
