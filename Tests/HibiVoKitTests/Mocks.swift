import Foundation

@testable import HibiVoKit

@MainActor
final class MockAudio: AudioCapturing {
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    var startCount = 0
    var failStart = false
    /// Blocks the caller like a slow engine start (Bluetooth mics) does.
    var startDelay: TimeInterval = 0

    func start(sampleRate: Double, deviceUID: String?) throws -> AsyncStream<AudioChunk> {
        if failStart { throw AudioCaptureError.microphonePermissionDenied }
        if startDelay > 0 { Thread.sleep(forTimeInterval: startDelay) }
        startCount += 1
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        self.continuation = continuation
        return stream
    }

    func speak(level: Float = 0.1, bytes: Int = 320) {
        continuation?.yield(AudioChunk(pcm16: Data(count: bytes), level: level))
    }

    func stop() {
        continuation?.finish()
        continuation = nil
    }
}

struct MockSecrets: SecretStore {
    var values: [String: String] = ["mock": "test-key"]
    func secret(for account: String) -> String? { values[account] }
    func setSecret(_ value: String?, for account: String) throws {}
}

final class MockTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {
    let id = "mock"
    let displayName = "Mock"
    let sampleRate: Double = 16_000
    let models = ["m1"]
    let defaultModel = "m1"
    let result: Result<String, TranscriptionError>
    private(set) var sessions: [MockTranscriptionSession] = []
    private(set) var lastConfig: TranscriptionConfig?

    init(result: Result<String, TranscriptionError> = .success("今日の15時からAWSのAppSyncについて打ち合わせをします")) {
        self.result = result
    }

    func makeSession(_ config: TranscriptionConfig) -> any TranscriptionSession {
        lastConfig = config
        let session = MockTranscriptionSession(result: result)
        sessions.append(session)
        return session
    }
}

actor MockTranscriptionSession: TranscriptionSession {
    nonisolated let partials: AsyncStream<String>
    private let result: Result<String, TranscriptionError>
    private(set) var receivedBytes = 0
    private(set) var didFinish = false
    private(set) var didCancel = false

    init(result: Result<String, TranscriptionError>) {
        self.result = result
        partials = AsyncStream { $0.finish() }
    }

    func start() async {}
    func send(_ pcm16: Data) async { receivedBytes += pcm16.count }
    func finish() async throws -> String {
        didFinish = true
        return try result.get()
    }
    func cancel() async { didCancel = true }
}

@MainActor
struct MockActiveApp: ActiveApplicationProviding {
    var app: TargetApplication? = TargetApplication(processID: 42, bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
    func frontmostApplication() -> TargetApplication? { app }
}

@MainActor
final class MockInserter: TextInserting {
    var outcome: InsertionOutcome = .pasted
    private(set) var inserted: [(text: String, target: TargetApplication?)] = []

    func insert(_ text: String, into target: TargetApplication?) async -> InsertionOutcome {
        inserted.append((text, target))
        return outcome
    }
}

@MainActor
final class MockDucker: OutputDucking {
    var isDucked = false
    var duckCount = 0

    func duck() {
        isDucked = true
        duckCount += 1
    }

    func restore() { isDucked = false }
}

final class MockMeetingProvider: MeetingTranscriptionProvider, @unchecked Sendable {
    let id = "mock"
    let displayName = "Mock"
    let sampleRate: Double = 16_000
    let models = ["m1"]
    let defaultModel = "m1"
    private(set) var sessions: [MockMeetingSession] = []
    private(set) var configs: [TranscriptionConfig] = []

    func makeSession(_ config: TranscriptionConfig) -> any TranscriptionSession {
        makeMeetingSession(config)
    }

    func makeMeetingSession(_ config: TranscriptionConfig) -> any MeetingTranscriptionSession {
        configs.append(config)
        let session = MockMeetingSession()
        sessions.append(session)
        return session
    }
}

actor MockMeetingSession: MeetingTranscriptionSession {
    nonisolated let partials: AsyncStream<String>
    nonisolated let events: AsyncStream<MeetingSessionEvent>
    private let continuation: AsyncStream<MeetingSessionEvent>.Continuation
    private(set) var receivedBytes = 0
    private(set) var didFinish = false
    private(set) var didCancel = false

    init() {
        partials = AsyncStream { $0.finish() }
        (events, continuation) = AsyncStream.makeStream()
    }

    func emit(_ event: MeetingSessionEvent) {
        continuation.yield(event)
        if case .ended = event { continuation.finish() }
    }

    func start() async {}
    func send(_ pcm16: Data) async { receivedBytes += pcm16.count }
    func finish() async throws -> String {
        didFinish = true
        continuation.finish()
        return ""
    }
    func cancel() async {
        didCancel = true
        continuation.finish()
    }
}

actor MockFileTranscriber: MeetingFileTranscriber {
    nonisolated let model = "mock-async"
    private var results: [Result<[MeetingToken], TranscriptionError>]
    private(set) var calls: [(bytes: Int, sampleRate: Int, config: TranscriptionConfig)] = []

    /// Each call takes the next result; the last one repeats.
    init(_ results: [Result<[MeetingToken], TranscriptionError>]) {
        self.results = results
    }

    func transcribe(pcm16: Data, sampleRate: Int, config: TranscriptionConfig) async throws -> [MeetingToken] {
        calls.append((pcm16.count, sampleRate, config))
        let result = results.count > 1 ? results.removeFirst() : results[0]
        return try result.get()
    }
}
