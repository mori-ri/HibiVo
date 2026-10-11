@preconcurrency import AVFoundation
import CoreAudio
import OSLog

/// Captures what the Mac is playing (the other side of an online meeting) with a Core Audio process tap.
///
/// A global mono tap is wrapped in a private aggregate device whose IO proc delivers the mixed output
/// of every app. This needs only the "system audio recording" permission, not screen recording. macOS
/// asks for it the first time the tap starts; while it is denied the tap delivers silence, not an error.
/// Like the microphone, audio lives only in memory.
@MainActor
public final class SystemAudioCaptureService: AudioCapturing {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private let queue = DispatchQueue(label: "io.github.mori-ri.hibivo.system-audio", qos: .userInitiated)
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "system-audio")

    public init() {}

    /// Process taps arrived in macOS 14.2.
    public static var isSupported: Bool {
        if #available(macOS 14.2, *) { true } else { false }
    }

    /// `deviceUID` is ignored: the tap follows whatever the apps are playing to.
    public func start(sampleRate: Double, deviceUID _: String?) throws -> AsyncStream<AudioChunk> {
        stop()
        guard #available(macOS 14.2, *) else {
            throw AudioCaptureError.engineFailed("システム音声の取得には macOS 14.2 以降が必要です")  // no-l10n
        }
        do {
            return try startTap(sampleRate: sampleRate)
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        continuation?.finish()
        continuation = nil
    }

    @available(macOS 14.2, *)
    private func startTap(sampleRate: Double) throws -> AsyncStream<AudioChunk> {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "HibiVo Meeting"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "create tap")

        // The aggregate needs a real device as its clock; the default output is what the apps play to.
        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "HibiVo Meeting Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]
            ],
        ]
        try Self.check(
            AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")

        var streamDescription = try Self.tapFormat(tapID)
        guard let format = AVAudioFormat(streamDescription: &streamDescription),
            let converter = PCMConverter(inputFormat: format, sampleRate: sampleRate)
        else {
            throw AudioCaptureError.engineFailed("システム音声のフォーマットを取得できません")  // no-l10n
        }

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        try Self.check(
            AudioDeviceCreateIOProcIDWithBlock(
                &procID, aggregateID, queue,
                Self.makeIOBlock(format: format, converter: converter, continuation: continuation)),
            "create IO proc")
        try Self.check(AudioDeviceStart(aggregateID, procID), "start")
        log.info("System audio tap started (\(format.sampleRate) Hz, \(format.channelCount) ch)")
        return stream
    }

    /// Built outside the main actor: the block runs on a real-time audio thread (see `AudioCaptureService`).
    nonisolated private static func makeIOBlock(
        format: AVAudioFormat, converter: PCMConverter, continuation: AsyncStream<AudioChunk>.Continuation
    ) -> AudioDeviceIOBlock {
        { _, inputData, _, _, _ in
            // The aggregate's input also carries the clock device's own input streams when it has
            // any (a USB headset is one device with a mic and speakers). The tap's mono stream is
            // added after the sub-device streams, so read only the last buffer.
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let tapBuffer = buffers.last else { return }
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: tapBuffer)
            let chunk = withUnsafePointer(to: &list) { pointer -> AudioChunk? in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: pointer, deallocator: nil)
                else { return nil }
                return converter.convert(buffer)
            }
            if let chunk { continuation.yield(chunk) }
        }
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            throw AudioCaptureError.engineFailed("システム音声を取得できません(\(step): \(status))")  // no-l10n
        }
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
            "default output")

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid), "output UID")
        guard let uid else { throw AudioCaptureError.engineFailed("出力デバイスを取得できません") }  // no-l10n
        return uid.takeRetainedValue() as String
    }

    @available(macOS 14.2, *)
    private static func tapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "tap format")
        return format
    }
}
