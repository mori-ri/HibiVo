import Foundation
import OSLog

/// Reads a small Codable value from Application Support and writes it back atomically off the main thread.
///
/// Saves are numbered: if two saves race, the writer drops the older one, so the file always ends up
/// with the latest value.
@MainActor
final class JSONFileStore<Value: Codable & Sendable> {
    let url: URL
    private let writer: Writer
    private var generation = 0

    init(url: URL) {
        self.url = url
        writer = Writer(url: url)
    }

    /// `~/Library/Application Support/HibiVo/<name>`
    static func appSupport(_ name: String) -> JSONFileStore {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return JSONFileStore(url: base.appending(path: "HibiVo").appending(path: name))
    }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder.iso.decode(Value.self, from: data)
        } catch {
            Logger.storage.error(
                "Could not decode \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    func save(_ value: Value) {
        generation += 1
        let generation = generation
        let writer = writer
        Task.detached(priority: .utility) {
            await writer.write(value, generation: generation)
        }
    }

    private actor Writer {
        let url: URL
        private var lastWritten = 0

        init(url: URL) {
            self.url = url
        }

        func write(_ value: Value, generation: Int) {
            guard generation > lastWritten else { return }
            lastWritten = generation
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder.iso.encode(value).write(to: url, options: [.atomic])
            } catch {
                Logger.storage.error(
                    "Could not save \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}

extension Logger {
    static let storage = Logger(subsystem: "io.github.mori-ri.hibivo", category: "storage")
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
