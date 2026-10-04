import AppKit

/// The app the transcript is pasted into: the one in front when recording stops, or the one from
/// key-down when HibiVo's own window is in front then.
public struct TargetApplication: Equatable, Sendable {
    public var processID: pid_t
    public var bundleID: String?
    public var name: String

    public init(processID: pid_t, bundleID: String?, name: String) {
        self.processID = processID
        self.bundleID = bundleID
        self.name = name
    }
}

@MainActor
public protocol ActiveApplicationProviding {
    func frontmostApplication() -> TargetApplication?
}

@MainActor
public struct ActiveApplicationService: ActiveApplicationProviding {
    public init() {}

    public func frontmostApplication() -> TargetApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return TargetApplication(
            processID: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "Unknown")
    }
}
