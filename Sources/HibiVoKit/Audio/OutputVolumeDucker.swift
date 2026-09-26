import AppKit
import AudioToolbox
import CoreAudio
import OSLog

/// Lowers the speaker volume while the user is dictating and puts it back afterwards.
@MainActor
public protocol OutputDucking: AnyObject {
    func duck()
    func restore()
}

/// Ducks the default output device's main volume through CoreAudio.
@MainActor
public final class SystemVolumeDucker: OutputDucking {
    /// Fraction of the user's volume kept while recording.
    static let duckedRatio: Float32 = 0.2

    private struct Ducked {
        var device: AudioDeviceID
        var original: Float32
        var ducked: Float32
    }

    private var current: Ducked?
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "audio")

    public init() {
        // Never leave the user's speakers turned down if the app quits mid-recording.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restore() }
        }
    }

    public func duck() {
        guard current == nil, let device = Self.defaultOutputDevice(), Self.isVolumeSettable(device),
            let original = Self.volume(of: device), original > 0
        else { return }
        let ducked = original * Self.duckedRatio
        guard Self.setVolume(ducked, of: device) else { return }
        current = Ducked(device: device, original: original, ducked: ducked)
    }

    public func restore() {
        guard let ducked = current else { return }
        current = nil
        // If the user changed the volume while recording, respect their choice.
        guard let now = Self.volume(of: ducked.device), abs(now - ducked.ducked) < 0.02 else {
            log.info("Output volume changed during recording; not restoring")
            return
        }
        Self.setVolume(ducked.original, of: ducked.device)
    }

    // MARK: - CoreAudio

    /// Virtual main volume works for devices that only expose per-channel volume, too.
    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
                == noErr, device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    private static func isVolumeSettable(_ device: AudioDeviceID) -> Bool {
        var address = volumeAddress
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func volume(of device: AudioDeviceID) -> Float32? {
        var address = volumeAddress
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    private static func setVolume(_ value: Float32, of device: AudioDeviceID) -> Bool {
        var address = volumeAddress
        var value = min(max(value, 0), 1)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
            == noErr
    }
}
