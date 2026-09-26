@preconcurrency import AVFoundation

/// A chunk of 16-bit little-endian mono PCM plus its loudness, ready for an STT provider.
public struct AudioChunk: Sendable {
    public var pcm16: Data
    /// RMS level in 0...1 (roughly), for the HUD meter and silence detection.
    public var level: Float

    public init(pcm16: Data, level: Float) {
        self.pcm16 = pcm16
        self.level = level
    }
}

/// Converts hardware-format tap buffers into mono Int16 PCM at the provider's sample rate.
///
/// Only ever used from the audio tap thread, one buffer at a time.
final class PCMConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let ratio: Double

    init?(inputFormat: AVAudioFormat, sampleRate: Double) {
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { return nil }
        self.converter = converter
        self.outputFormat = outputFormat
        self.ratio = sampleRate / inputFormat.sampleRate
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AudioChunk? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        // The input block runs synchronously inside convert(), so this is never shared across threads.
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let samples = output.int16ChannelData?[0] else {
            return nil
        }
        let count = Int(output.frameLength)
        let data = Data(bytes: samples, count: count * MemoryLayout<Int16>.size)
        return AudioChunk(pcm16: data, level: Self.rms(samples, count: count))
    }

    static func rms(_ samples: UnsafePointer<Int16>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            let s = Float(samples[i]) / Float(Int16.max)
            sum += s * s
        }
        return (sum / Float(count)).squareRoot()
    }
}
