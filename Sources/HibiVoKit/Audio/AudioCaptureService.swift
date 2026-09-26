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
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "audio")

    public init() {}

    public static var permissionStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Starts the microphone. The returned stream finishes when `stop()` is called.
    /// - Parameter deviceUID: CoreAudio device UID, or nil for the system default input.
    public func start(sampleRate: Double, deviceUID: String?) throws -> AsyncStream<AudioChunk> {
        stop()
        guard Self.permissionStatus == .authorized else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceUID, let deviceID = AudioDeviceCatalog.deviceID(forUID: deviceUID) {
            Self.setInputDevice(deviceID, on: input)
        }

        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
            let converter = PCMConverter(inputFormat: hardwareFormat, sampleRate: sampleRate)
        else {
            throw AudioCaptureError.engineFailed("入力デバイスのフォーマットを取得できません")
        }

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        input.installTap(
            onBus: 0, bufferSize: 1024, format: hardwareFormat,
            block: Self.makeTapBlock(converter: converter, continuation: continuation))

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            throw AudioCaptureError.engineFailed(error.localizedDescription)
        }
        self.engine = engine
        self.continuation = continuation
        return stream
    }

    public func stop() {
        guard let engine else { return }
        // Remove the tap before stopping the engine; the reverse order can crash on some devices.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        continuation?.finish()
        continuation = nil
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

    private static func setInputDevice(_ deviceID: AudioDeviceID, on input: AVAudioInputNode) {
        guard let unit = input.audioUnit else { return }
        var id = deviceID
        AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    }
}
