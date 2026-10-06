import Foundation
import OSLog

/// What it takes to finish an after-meeting meeting from its saved audio, e.g. after a shutdown.
struct MeetingRecordingInfo: Codable, Equatable, Sendable {
    var startedAt: Date
    /// nil while recording, or when the app quit before the recording could be stopped.
    var endedAt: Date?
    var providerID: String
    var model: String
    var language: String
    var vocabulary: [VocabularyEntry]
    var includesSystemAudio: Bool
    /// Final once `endedAt` is set.
    var notices: [MeetingDocument.Notice]
    var notes: String
    /// Set once the audio is on the provider's side, so the result can be fetched without uploading again.
    var job: MeetingFileJob?
}

/// Keeps the audio of after-meeting meetings on disk until they have been transcribed, so a shutdown,
/// a sleep or a failed request doesn't lose the meeting. Each recording is `<id>.pcm` (mono PCM16) with
/// `<id>.json` (`MeetingRecordingInfo`), readable by the user only and excluded from backups. Both are
/// deleted once the transcript is saved, and recordings that could not be transcribed within
/// `lifetime` are dropped.
actor MeetingRecordingStore {
    static let lifetime: TimeInterval = 7 * 24 * 3600

    struct Pending: Sendable {
        var id: String
        var info: MeetingRecordingInfo
        /// When the audio was last written: the end of a recording the app never got to stop.
        var lastWrittenAt: Date?
    }

    let directory: URL
    private var handles: [String: FileHandle] = [:]
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "meeting")

    init(directory: URL) {
        self.directory = directory
    }

    @discardableResult
    func save(_ info: MeetingRecordingInfo, id: String) -> Bool {
        do {
            try prepareDirectory()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try write(encoder.encode(info), to: infoURL(id))
            return true
        } catch {
            log.error("Could not save meeting recording info: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func append(_ pcm16: Data, id: String) -> Bool {
        do {
            let handle: FileHandle
            if let open = handles[id] {
                handle = open
            } else {
                try prepareDirectory()
                let url = audioURL(id)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil, attributes: Self.ownerOnly)
                }
                handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                handles[id] = handle
            }
            try handle.write(contentsOf: pcm16)
            return true
        } catch {
            log.error("Could not save meeting audio: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func closeAudio(id: String) {
        try? handles.removeValue(forKey: id)?.close()
    }

    func audio(id: String) -> Data? {
        try? Data(contentsOf: audioURL(id))
    }

    func remove(id: String) {
        closeAudio(id: id)
        try? FileManager.default.removeItem(at: audioURL(id))
        try? FileManager.default.removeItem(at: infoURL(id))
    }

    /// Every saved recording, oldest first.
    func pending() -> [Pending] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            let id = String(name.dropLast(5))
            guard let data = try? Data(contentsOf: infoURL(id)),
                let info = try? decoder.decode(MeetingRecordingInfo.self, from: data)
            else {
                // Unreadable info can never be transcribed.
                remove(id: id)
                return nil
            }
            let written = try? FileManager.default.attributesOfItem(atPath: audioURL(id).path)[.modificationDate]
            return Pending(id: id, info: info, lastWrittenAt: written as? Date)
        }
        .sorted { $0.info.startedAt < $1.info.startedAt }
    }

    // MARK: - Files

    private static var ownerOnly: [FileAttributeKey: Any] { [.posixPermissions: 0o600] }

    private func audioURL(_ id: String) -> URL { directory.appending(path: "\(id).pcm") }
    private func infoURL(_ id: String) -> URL { directory.appending(path: "\(id).json") }

    private func prepareDirectory() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Meeting audio has no place in Time Machine; it only waits here to be transcribed.
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(Self.ownerOnly, ofItemAtPath: url.path)
    }
}
