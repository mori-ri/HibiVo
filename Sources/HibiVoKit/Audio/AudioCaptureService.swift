@preconcurrency import AVFoundation
import CoreAudio
import OSLog

public enum AudioCaptureError: Error, Equatable {
    case microphonePermissionDenied
    case engineFailed(String)
}

/// Abstracts the microphone so the dictation flow can be tested without hardware.
@MainActor
public protocol AudioCapturing: AnyObject {
    func start(sampleRate: Double, deviceUID: String?) throws -> AsyncStream<AudioChunk>
    func stop()
}

/// Captures microphone audio with AVAudioEngine and streams converted PCM chunks.
///
/// Audio lives only in memory: chunks are handed to the caller and never written to disk.
/// A fresh engine is created per recording so device changes (AirPods, USB mics) are picked up.
@MainActor
public final class AudioCaptureService: AudioCapturing {
    private var engine: (any MicrophoneEngine)?
    private var observation: AudioConfigurationObservation?
    private var recovery: Task<Void, Never>?
    private var recordingID = UUID()
    private var engineID = UUID()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var sampleRate: Double = 0
    private var deviceUID: String?
    private let makeEngine: @MainActor () -> any MicrophoneEngine
    private let hasPermission: @MainActor () -> Bool
    private let notificationCenter: NotificationCenter
    private let recoveryDelays: [Duration]
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "audio")

    public convenience init() {
        self.init(
            makeEngine: { AVMicrophoneEngine() },
            hasPermission: { Self.permissionStatus == .authorized })
    }

    /// Hardware and delays are injectable so recovery can be tested without recording real audio.
    init(
        makeEngine: @escaping @MainActor () -> any MicrophoneEngine,
        hasPermission: @escaping @MainActor () -> Bool,
        notificationCenter: NotificationCenter = .default,
        recoveryDelays: [Duration] = [.milliseconds(200), .milliseconds(500), .seconds(1)]
    ) {
        self.makeEngine = makeEngine
        self.hasPermission = hasPermission
        self.notificationCenter = notificationCenter
        self.recoveryDelays = recoveryDelays.isEmpty ? [.zero] : recoveryDelays
    }

    public static var permissionStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Starts the microphone. Recovery keeps this stream open; an unrecoverable failure ends it.
    /// - Parameter deviceUID: CoreAudio device UID, or nil for the system default input.
    ///   A disconnected selected device falls back to the system default without changing settings.
    public func start(sampleRate: Double, deviceUID: String?) throws -> AsyncStream<AudioChunk> {
        stop()
        guard hasPermission() else {
            throw AudioCaptureError.microphonePermissionDenied
        }
        self.sampleRate = sampleRate
        self.deviceUID = deviceUID
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        do {
            try startEngine()
        } catch {
            stop()
            throw error
        }
        return stream
    }

    public func stop() {
        recordingID = UUID()
        recovery?.cancel()
        recovery = nil
        stopEngine()
        continuation?.finish()
        continuation = nil
    }

    private func startEngine() throws {
        guard let continuation else { return }
        let engine = makeEngine()
        self.engine = engine
        engineID = UUID()
        let currentRecording = recordingID
        let currentEngine = engineID
        observation = AudioConfigurationObservation(
            center: notificationCenter, object: engine.notificationObject
        ) { [weak self] in
            // Never tear down an engine on its internal notification queue (it can deadlock).
            Task { @MainActor [weak self] in
                guard let self, self.recordingID == currentRecording, self.engineID == currentEngine else { return }
                self.recover()
            }
        }
        do {
            try engine.start(sampleRate: sampleRate, deviceUID: deviceUID, continuation: continuation)
        } catch {
            stopEngine()
            throw error
        }
    }

    private func stopEngine() {
        observation = nil
        engine?.stop()
        engine = nil
    }

    private func recover() {
        guard continuation != nil, recovery == nil else { return }
        stopEngine()
        let currentRecording = recordingID
        recovery = Task { [weak self, recoveryDelays] in
            for delay in recoveryDelays {
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, self.recordingID == currentRecording, !Task.isCancelled else { return }
                do {
                    try self.startEngine()
                    self.recovery = nil
                    self.log.info("Microphone restarted after a configuration change")
                    return
                } catch {
                    self.log.error("Microphone restart failed: \(String(describing: error), privacy: .public)")
                }
            }
            guard let self, self.recordingID == currentRecording else { return }
            // An unexpected stream end tells the meeting controller to save and report the failure.
            self.stop()
        }
    }
}

/// Owns the observer independently of actor isolation, including removal on deallocation.
private final class AudioConfigurationObservation {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, object: AnyObject, changed: @escaping @Sendable () -> Void) {
        self.center = center
        token = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: object, queue: nil) { _ in
            changed()
        }
    }

    deinit { center.removeObserver(token) }
}

@MainActor
protocol MicrophoneEngine: AnyObject {
    var notificationObject: AnyObject { get }
    func start(sampleRate: Double, deviceUID: String?, continuation: AsyncStream<AudioChunk>.Continuation) throws
    func stop()
}

@MainActor
private final class AVMicrophoneEngine: MicrophoneEngine {
    private let engine = AVAudioEngine()
    private var hasTap = false
    var notificationObject: AnyObject { engine }

    func start(sampleRate: Double, deviceUID: String?, continuation: AsyncStream<AudioChunk>.Continuation) throws {
        let input = engine.inputNode
        if let deviceUID, let deviceID = AudioDeviceCatalog.deviceID(forUID: deviceUID) {
            try Self.setInputDevice(deviceID, on: input)
        }
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
            let converter = PCMConverter(inputFormat: hardwareFormat, sampleRate: sampleRate)
        else {
            throw AudioCaptureError.engineFailed("入力デバイスのフォーマットを取得できません")
        }
        input.installTap(
            onBus: 0, bufferSize: 1024, format: hardwareFormat,
            block: Self.makeTapBlock(converter: converter, continuation: continuation))
        hasTap = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioCaptureError.engineFailed(error.localizedDescription)
        }
    }

    func stop() {
        // Remove the tap before stopping the engine; the reverse order can crash on some devices.
        if hasTap { engine.inputNode.removeTap(onBus: 0) }
        hasTap = false
        engine.stop()
    }

    /// Built outside the main actor: the tap runs on a real-time audio thread, and a closure
    /// formed inside a @MainActor method would trap on Swift 6's isolation check.
    nonisolated private static func makeTapBlock(
        converter: PCMConverter, continuation: AsyncStream<AudioChunk>.Continuation
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            if let chunk = converter.convert(buffer) {
                continuation.yield(chunk)
            }
        }
    }

    private static func setInputDevice(_ deviceID: AudioDeviceID, on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else {
            throw AudioCaptureError.engineFailed("入力デバイスを設定できません")
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw AudioCaptureError.engineFailed("入力デバイスを設定できません (\(status))")
        }
    }
}
