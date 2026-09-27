import Foundation
import OSLog

/// Gemini 3.5 Transcribe over the Live API. The API key is shared with Gemini cleanup
/// (`SecretAccount.gemini` is this provider's ID).
public struct GeminiLiveProvider: TranscriptionProvider {
    public let id = "gemini"
    public let displayName = "Google Gemini"
    public let sampleRate: Double = 16_000
    public let models = ["gemini-3.5-transcribe-live"]
    public let defaultModel = "gemini-3.5-transcribe-live"

    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func makeSession(_ config: TranscriptionConfig) -> any TranscriptionSession {
        GeminiLiveSession(config: config, sampleRate: sampleRate, urlSession: urlSession)
    }
}

/// One Live API connection for one utterance.
///
/// Audio sent before `setupComplete` is buffered, so speech from the moment the key goes down is
/// never lost. On `finish()` we send `activityEnd` and wait for the finalized transcription.
actor GeminiLiveSession: TranscriptionSession {
    static let finalizeTimeout: Duration = .seconds(4)
    /// Transcriptions are not ordered relative to `turnComplete`, so after the last signal we
    /// wait briefly for stragglers before returning.
    static let settleDelay: Duration = .milliseconds(400)

    nonisolated let partials: AsyncStream<String>
    private let partialsContinuation: AsyncStream<String>.Continuation
    private let config: TranscriptionConfig
    private let sampleRate: Double
    private let urlSession: URLSession
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "gemini-live")

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var isReady = false
    private var isClosed = false
    private var finalizeRequested = false
    private var activityEnded = false
    private var segmentSinceEnd = false
    private var isDone = false
    private var pending: [Data] = []
    private var transcript = GeminiLiveTranscript()
    private var failure: TranscriptionError?
    private var waiter: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?

    init(config: TranscriptionConfig, sampleRate: Double, urlSession: URLSession) {
        self.config = config
        self.sampleRate = sampleRate
        self.urlSession = urlSession
        (partials, partialsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func start() async {
        guard socket == nil, !isClosed else { return }
        let socket = urlSession.webSocketTask(with: GeminiLiveProtocol.url(apiKey: config.apiKey))
        self.socket = socket
        socket.resume()
        receiveTask = Task { await self.receiveLoop(socket) }

        do {
            // Audio waits in `pending` until the server answers with `setupComplete`.
            try await socket.send(.string(GeminiLiveProtocol.setup(for: config)))
        } catch {
            fail(Self.error(for: socket, error))
        }
    }

    func send(_ pcm16: Data) {
        guard !isClosed, failure == nil else { return }
        if isReady { sendAudio(pcm16) } else { pending.append(pcm16) }
    }

    func finish() async throws -> String {
        var waitError: TranscriptionError?
        if failure == nil, !isDone {
            finalizeRequested = true
            if isReady { sendActivityEnd() }
            do {
                try await waitForFinalize()
            } catch {
                waitError = error as? TranscriptionError ?? .network(error.localizedDescription)
            }
        }
        close()
        // On timeout or a dropped connection, keep whatever we have (including interim text)
        // rather than losing the utterance.
        let text = transcript.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, let error = failure ?? waitError { throw error }
        if let error = failure ?? waitError {
            log.notice("Returning partial transcript after \(String(describing: error))")
        }
        return text
    }

    func cancel() {
        fail(.cancelled)
        close()
    }

    // MARK: - Private

    private func enqueue(_ text: String) {
        socket?.send(.string(text)) { _ in }  // Failures surface through the receive loop.
    }

    private func sendAudio(_ pcm16: Data) {
        enqueue(GeminiLiveProtocol.audioMessage(pcm16, sampleRate: sampleRate))
    }

    private func sendActivityEnd() {
        guard !activityEnded else { return }
        activityEnded = true
        enqueue(GeminiLiveProtocol.activityEndMessage)
    }

    private func handleSetupComplete() {
        guard !isReady, !isClosed else { return }
        // Flush synchronously (no suspension) so ordering with later `send` calls is preserved.
        enqueue(GeminiLiveProtocol.activityStartMessage)
        for chunk in pending { sendAudio(chunk) }
        pending.removeAll()
        isReady = true
        if finalizeRequested { sendActivityEnd() }
    }

    private func waitForFinalize() async throws {
        if let failure { throw failure }
        try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
            timeoutTask = Task {
                try? await Task.sleep(for: Self.finalizeTimeout)
                self.resolve(.failure(.timedOut))
            }
        }
    }

    private func resolve(_ result: Result<Void, TranscriptionError>) {
        if case .success = result { isDone = true }
        settleTask?.cancel()
        guard let waiter else { return }
        self.waiter = nil
        timeoutTask?.cancel()
        waiter.resume(with: result)
    }

    private func settle() {
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self.resolve(.success(()))
        }
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                if !isClosed { fail(Self.error(for: socket, error)) }
                return
            }
            handle(message)
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let d): data = d
        @unknown default: return
        }
        guard let response = try? JSONDecoder().decode(GeminiLiveProtocol.Response.self, from: data) else {
            return
        }
        if response.setupComplete != nil { handleSetupComplete() }
        guard let content = response.serverContent else { return }

        let gotSegment = transcript.apply(content)
        partialsContinuation.yield(transcript.displayText)
        guard activityEnded else { return }
        if gotSegment { segmentSinceEnd = true }
        // Done once the turn is complete and its final segment has arrived. Either may come first,
        // and a turn with no speech may never produce a segment, so both paths end in `settle()`.
        if transcript.didCompleteTurn, segmentSinceEnd {
            resolve(.success(()))
        } else if gotSegment || content.turnComplete == true {
            settle()
        }
    }

    private func fail(_ error: TranscriptionError) {
        if failure == nil { failure = error }
        resolve(.failure(error))
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        receiveTask?.cancel()
        timeoutTask?.cancel()
        settleTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        partialsContinuation.finish()
    }

    /// The Live API reports a bad key by closing the socket with a reason, not with a message.
    static func error(for socket: URLSessionWebSocketTask, _ error: Error) -> TranscriptionError {
        if let http = socket.response as? HTTPURLResponse, [401, 403].contains(http.statusCode) {
            return .unauthorized
        }
        let reason = socket.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return classify(closeCode: socket.closeCode, reason: reason) ?? .network(error.localizedDescription)
    }

    static func classify(closeCode: URLSessionWebSocketTask.CloseCode, reason: String) -> TranscriptionError? {
        if reason.localizedCaseInsensitiveContains("API key") || reason.contains("API_KEY") {
            return .unauthorized
        }
        guard closeCode != .invalid else { return nil }
        return .server(reason.isEmpty ? "close code \(closeCode.rawValue)" : reason)
    }
}
