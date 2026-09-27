import Foundation
import OSLog

public struct SonioxProvider: TranscriptionProvider {
    public let id = "soniox"
    public let displayName = "Soniox"
    public let sampleRate: Double = 16_000
    public let models = ["stt-rt-v5"]
    public let defaultModel = "stt-rt-v5"

    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func makeSession(_ config: TranscriptionConfig) -> any TranscriptionSession {
        SonioxSession(config: config, sampleRate: sampleRate, urlSession: urlSession)
    }
}

/// One Soniox WebSocket connection for one utterance.
///
/// Audio sent before the connection is ready is buffered, so speech from the moment the key goes
/// down is never lost. On `finish()` we send a short tail of silence plus `finalize`, then wait for
/// the `<fin>` token, which marks every earlier token as final.
actor SonioxSession: TranscriptionSession {
    static let finalizeTimeout: Duration = .seconds(4)
    /// Soniox recommends a little trailing silence before a manual finalize.
    static let trailingSilence = Data(count: 16_000 * 2 / 5)  // 200 ms of PCM16 @ 16 kHz

    nonisolated let partials: AsyncStream<String>
    private let partialsContinuation: AsyncStream<String>.Continuation
    private let config: TranscriptionConfig
    private let sampleRate: Double
    private let urlSession: URLSession
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "soniox")

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var isReady = false
    private var isClosed = false
    private var finalizeRequested = false
    private var pending: [Data] = []
    private var transcript = SonioxTranscript()
    private var failure: TranscriptionError?
    private var waiter: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(config: TranscriptionConfig, sampleRate: Double, urlSession: URLSession) {
        self.config = config
        self.sampleRate = sampleRate
        self.urlSession = urlSession
        (partials, partialsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func start() async {
        guard socket == nil, !isClosed else { return }
        let socket = urlSession.webSocketTask(with: SonioxProtocol.endpoint)
        self.socket = socket
        socket.resume()
        receiveTask = Task { await self.receiveLoop(socket) }

        do {
            // Completes once the handshake is done; audio arriving meanwhile goes to `pending`.
            try await socket.send(.string(SonioxProtocol.config(for: config, sampleRate: sampleRate)))
        } catch {
            fail(.network(error.localizedDescription))
            return
        }
        guard !isClosed else { return }
        // Flush synchronously (no suspension) so ordering with later `send` calls is preserved.
        for chunk in pending { enqueue(.data(chunk)) }
        pending.removeAll()
        isReady = true
        if finalizeRequested { sendFinalize() }
    }

    func send(_ pcm16: Data) {
        guard !isClosed, failure == nil else { return }
        if isReady { enqueue(.data(pcm16)) } else { pending.append(pcm16) }
    }

    func finish() async throws -> String {
        var waitError: TranscriptionError?
        if failure == nil, !transcript.didFinalize {
            finalizeRequested = true
            if isReady { sendFinalize() }
            do {
                try await waitForFinalize()
            } catch {
                waitError = error as? TranscriptionError ?? .network(error.localizedDescription)
            }
        }
        close()
        // After a successful finalize every token is final. On timeout or a dropped connection,
        // keep whatever we have (including tentative text) rather than losing the utterance.
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

    private func enqueue(_ message: URLSessionWebSocketTask.Message) {
        socket?.send(message) { _ in }  // Failures surface through the receive loop.
    }

    private func sendFinalize() {
        enqueue(.data(Self.trailingSilence))
        enqueue(.string(SonioxProtocol.finalizeMessage))
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
        guard let waiter else { return }
        self.waiter = nil
        timeoutTask?.cancel()
        waiter.resume(with: result)
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                if !isClosed { fail(.network(error.localizedDescription)) }
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
        guard let response = try? JSONDecoder().decode(SonioxProtocol.Response.self, from: data) else {
            return
        }
        if let code = response.errorCode {
            log.error("Soniox error \(code): \(response.errorMessage ?? "", privacy: .public)")
            fail(code == 401 ? .unauthorized : .server(response.errorMessage ?? "\(code)"))
            return
        }
        transcript.apply(response)
        partialsContinuation.yield(transcript.displayText)
        if transcript.didFinalize || transcript.didFinish { resolve(.success(())) }
    }

    private func fail(_ error: TranscriptionError) {
        if failure == nil { failure = error }
        resolve(.failure(error))
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        receiveTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        partialsContinuation.finish()
    }
}
