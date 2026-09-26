import AppKit

/// Quits and starts a fresh copy, e.g. after granting permissions or when the hotkey tap gets stuck.
public enum AppRelauncher {
    @MainActor
    public static func relaunch() {
        // A detached shell waits for this process to exit, then starts the app again. Launching
        // first would hand the new copy a second instance fighting over the hotkey tap.
        let bundleURL = Bundle.main.bundleURL
        let launch = bundleURL.pathExtension == "app"
            ? "/usr/bin/open -n \(shellQuoted(bundleURL.path))"
            // `swift run` has no bundle; start the bare executable instead.
            : "\(shellQuoted(Bundle.main.executablePath ?? CommandLine.arguments[0])) >/dev/null 2>&1 &"
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; \(launch)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do {
            try process.run()
        } catch {
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }

    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
