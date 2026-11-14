@preconcurrency import AVFoundation
import OSLog
import os

/// The microphone of one dictation session.
///
/// A keyboard extension can't record, and iOS only lets an app start recording while it is in front.
/// So the app turns the microphone on once, in the foreground, and keeps the audio engine running
/// after the user goes back to the app they are typing in (the `audio` background mode keeps the app
/// alive for as long as it records). Between dictations the audio is thrown away as it arrives;
/// `beginCapture` starts handing it out.
@MainActor
final class MicrophoneSession {
    enum Permission {
        case undetermined
        case denied
        case granted
    }

    enum Failure: Error {
        case permissionDenied
        case engineFailed(String)
    }

    private(set) var isActive = false
    /// Called when iOS takes the microphone away (a phone call, another app recording) and it can't be
    /// taken back from the background. The session is already deactivated when this runs.
    var onLost: (@MainActor () -> Void)?

    private var engine: AVAudioEngine?
    private let sink = AudioSink()
    private var observers: [any NSObjectProtocol] = []
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "audio")

    static var permission: Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .undetermined
        @unknown default: .undetermined
        }
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Turns the microphone on. Only works while the app is in the foreground.
    func activate() throws {
        guard !isActive else { return }
        guard Self.permission == .granted else { throw Failure.permissionDenied }
        do {
            let session = AVAudioSession.sharedInstance()
            // Mixing keeps the user's music playing; without `defaultToSpeaker` it would move to the earpiece.
            // Bluetooth microphones are left out on purpose: holding one open for the whole session would
            // drop headphones to call quality.
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
            try startEngine()
        } catch {
            log.error("Microphone start failed: \(String(describing: error), privacy: .public)")
            deactivate()
            throw Failure.engineFailed(error.localizedDescription)
        }
        observe()
        isActive = true
    }

    func deactivate() {
        endCapture()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        stopEngine()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isActive = false
    }

    /// Starts handing out audio as mono PCM16 at `sampleRate`. The stream ends at `endCapture`.
    func beginCapture(sampleRate: Double) -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        sink.begin(sampleRate: sampleRate, continuation: continuation)
        return stream
    }

    func endCapture() {
        sink.end()
    }

    // MARK: - Engine

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw Failure.engineFailed("No input format")
        }
        sink.setFormat(format)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTapBlock(sink: sink))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    private func stopEngine() {
        guard let engine else { return }
        // Remove the tap before stopping the engine; the reverse order can crash on some devices.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// Built outside the main actor: the tap runs on an audio thread, and a closure formed inside a
    /// @MainActor method would trap on Swift 6's isolation check.
    nonisolated private static func makeTapBlock(sink: AudioSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.write(buffer) }
    }

    // MARK: - Interruptions

    private func observe() {
        let center = NotificationCenter.default
        // The input changed (headphones plugged in, a call ended): the engine has stopped and needs a
        // new tap in the new format.
        let configuration = center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.restartEngine() }
        }
        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in self?.lose() }
        }
        let reset = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.lose() }
        }
        observers = [configuration, interruption, reset]
    }

    private func restartEngine() {
        guard isActive else { return }
        stopEngine()
        do {
            try startEngine()
            // The old engine's observer is gone with it; watch the new one.
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observe()
            log.info("Microphone restarted after a configuration change")
        } catch {
            log.error("Microphone restart failed: \(String(describing: error), privacy: .public)")
            lose()
        }
    }

    private func lose() {
        guard isActive else { return }
        deactivate()
        onLost?()
    }
}

/// Where the audio tap puts its buffers: nowhere between dictations, into a stream during one.
private final class AudioSink: @unchecked Sendable {
    private struct State {
        var format: AVAudioFormat?
        var sampleRate: Double = 0
        var continuation: AsyncStream<AudioChunk>.Continuation?
        var converter: PCMConverter?

        mutating func makeConverter() {
            guard let format, continuation != nil else {
                converter = nil
                return
            }
            converter = PCMConverter(inputFormat: format, sampleRate: sampleRate)
        }
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    /// The hardware format the tap delivers. Changes when the engine is restarted for another input.
    func setFormat(_ format: AVAudioFormat) {
        state.withLockUnchecked {
            $0.format = format
            $0.makeConverter()
        }
    }

    func begin(sampleRate: Double, continuation: AsyncStream<AudioChunk>.Continuation) {
        state.withLockUnchecked {
            $0.continuation?.finish()
            $0.sampleRate = sampleRate
            $0.continuation = continuation
            $0.makeConverter()
        }
    }

    func end() {
        state.withLockUnchecked {
            $0.continuation?.finish()
            $0.continuation = nil
            $0.converter = nil
        }
    }

    /// Called on the audio tap's thread.
    func write(_ buffer: AVAudioPCMBuffer) {
        state.withLockUnchecked {
            guard let continuation = $0.continuation, let chunk = $0.converter?.convert(buffer) else { return }
            continuation.yield(chunk)
        }
    }
}
