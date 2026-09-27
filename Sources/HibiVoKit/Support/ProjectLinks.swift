import AppKit

/// Public GitHub pages the app links to. Feedback goes to Discussions, not Issues, so that
/// questions and ideas don't have to be phrased as bug reports.
public enum ProjectLinks {
    public static let repository = URL(string: "https://github.com/mori-ri/HibiVo")!
    public static let discussions = URL(string: "https://github.com/mori-ri/HibiVo/discussions")!
    public static let newFeedback = URL(string: "https://github.com/mori-ri/HibiVo/discussions/new?category=feedback")!

    public static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
