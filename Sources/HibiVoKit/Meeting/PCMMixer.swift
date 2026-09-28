import Foundation

/// Mixes two mono PCM16 streams at the same sample rate into one, so a single STT session hears
/// both the microphone and the system audio. Pure so it can be unit tested.
///
/// The sources deliver chunks on their own schedules (and clocks), so samples are queued per source
/// and mixed once both have them. If one source falls silent entirely (a stalled device, no tap),
/// the other is not held back for more than `maximumLag`: the missing samples count as silence.
struct PCMMixer {
    enum Input: Int, CaseIterable {
        case microphone, system
    }

    let maximumLag: Int
    private var queues: [[Int16]] = [[], []]

    /// - Parameter maximumLag: In samples; how far one source may run ahead before it is sent alone.
    init(maximumLag: Int) {
        self.maximumLag = maximumLag
    }

    /// Queues a chunk and returns whatever can be mixed now, or nil if nothing is ready.
    mutating func push(_ pcm16: Data, from input: Input) -> Data? {
        queues[input.rawValue] += Self.samples(pcm16)
        let counts = queues.map(\.count)
        let ready = max(counts.min() ?? 0, (counts.max() ?? 0) - maximumLag)
        return ready > 0 ? mix(ready) : nil
    }

    /// Mixes everything still queued, padding the shorter source with silence. Call once both sources ended.
    mutating func flush() -> Data? {
        let remaining = queues.map(\.count).max() ?? 0
        return remaining > 0 ? mix(remaining) : nil
    }

    private mutating func mix(_ count: Int) -> Data {
        var mixed = [Int16](repeating: 0, count: count)
        for index in queues.indices {
            let queue = queues[index]
            for i in 0..<min(count, queue.count) {
                // Sum and clamp: the voices rarely overlap at full scale, and clipping beats halving
                // everyone's volume.
                mixed[i] = Int16(clamping: Int32(mixed[i]) + Int32(queue[i]))
            }
            queues[index].removeFirst(min(count, queue.count))
        }
        return mixed.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func samples(_ data: Data) -> [Int16] {
        // Copy rather than rebind: a Data slice need not be aligned for Int16.
        var samples = [Int16](repeating: 0, count: data.count / 2)
        samples.withUnsafeMutableBytes { _ = data.copyBytes(to: $0) }
        return samples
    }
}
