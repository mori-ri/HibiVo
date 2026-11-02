// Renders the real app views with made-up sample data for the landing page. Run through
// scripts/make-screenshots.sh, which points the app's data at an empty temporary home: this tool must never
// see the data of the person running it, because the images are published.
//
// Windows are captured from inside this process, so no Screen Recording permission is needed. They're
// placed off screen and never take focus.

import AppKit
import CoreGraphics
import SwiftUI

@testable import HibiVoKit

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: HibiVoScreenshots <ja|en> <output directory>")
    exit(2)
}
let language = arguments[1]
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)

// The stores read Application Support, so make sure that isn't the real one.
guard let fixedHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
    support.path.contains(URL(fileURLWithPath: fixedHome).lastPathComponent),
    !FileManager.default.fileExists(atPath: support.appending(path: "HibiVo").path)
else {
    print("Refusing to run: use scripts/make-screenshots.sh, which isolates the app's data.")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Answered up front so the one-time migrations don't take the sample keys for an existing user's.
let defaultsDomain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
UserDefaults.standard.removePersistentDomain(forName: defaultsDomain)
UserDefaults.standard.set(true, forKey: "transcriptionDefaultsMigrated")
UserDefaults.standard.set(true, forKey: "minutesDefaultsMigrated")
UserDefaults.standard.set(true, forKey: "appModeOverridesSeeded")

@MainActor
func wait(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// Stays where it's put: a window on the very edge of a screen would otherwise be pulled back on.
final class ShotWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Takes its scale from the Retina display it barely touches: a single point of it is on screen.
@MainActor
func capture(_ window: NSWindow, to name: String) throws {
    guard let retina = NSScreen.screens.first(where: { $0.backingScaleFactor >= 2 }) else {
        print("A Retina display is needed for 2x images.")
        exit(1)
    }
    let frame = retina.frame
    window.setFrameOrigin(NSPoint(x: frame.maxX - 1, y: frame.minY - window.frame.height + 1))
    window.orderFrontRegardless()
    wait(1.5)
    guard
        let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])
    else { throw CocoaError(.fileWriteUnknown) }
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    try data?.write(to: output.appending(path: "\(name).png"))
    print("Wrote \(name).png (\(image.width)×\(image.height))")
    window.orderOut(nil)
}

@MainActor
func captureMainWindow(_ env: AppEnvironment, section: MainSection, height: CGFloat, name: String) throws {
    env.state.mainSection = section
    for (appearance, suffix) in [(NSAppearance.Name.aqua, ""), (.darkAqua, "-dark")] {
        let window = ShotWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainWindowView(env: env))
        try capture(window, to: "\(name)-\(language)\(suffix)")
    }
}

@MainActor
func captureHUD(_ env: AppEnvironment, name: String) throws {
    let hosting = NSHostingView(rootView: HUDView(state: env.state, settings: env.settings).padding(1))
    hosting.frame.size = hosting.fittingSize
    let window = ShotWindow(
        contentRect: NSRect(origin: .zero, size: hosting.frame.size), styleMask: [.borderless], backing: .buffered,
        defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    try capture(window, to: "\(name)-\(language)")
}

@MainActor
func run() throws {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let env = AppEnvironment(secrets: SampleSecrets())
    Sample(language: language).fill(env)

    try captureMainWindow(env, section: .home, height: 652, name: "home")
    try captureMainWindow(env, section: .vocabulary, height: 600, name: "vocabulary")

    env.state.audioLevel = 0.75
    env.state.meetingStartedAt = Date().addingTimeInterval(-754)
    env.state.phase = .meeting
    try captureHUD(env, name: "hud-meeting")
    UserDefaults.standard.removePersistentDomain(forName: defaultsDomain)
}

/// Keeps the tool away from the real Keychain. Every provider looks configured, with a key that means nothing.
struct SampleSecrets: SecretStore {
    func secret(for account: String) -> String? { "sample" }
    func setSecret(_ value: String?, for account: String) throws {}
}

struct Sample {
    let language: String
    private var isEnglish: Bool { language == "en" }

    @MainActor
    func fill(_ env: AppEnvironment) {
        let now = Date()
        for (offset, dictations) in [(6, 18), (5, 31), (4, 24), (3, 42), (2, 37), (1, 29), (0, 21)] {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: now) else { continue }
            env.usage.record(
                UsageEvent(
                    date: date, dictations: dictations, characters: dictations * 74,
                    transcription: TranscriptionUsage(
                        provider: "apple", model: "", seconds: Double(dictations) * 19)))
        }
        let terms: [(String, String)] =
            isEnglish
            ? [("AppSync", "app sink"), ("Kubernetes", "cooper netties"), ("HibiVo", "hibby voh")]
            : [("AppSync", "アップシンク"), ("Kubernetes", "クーバネティス"), ("HibiVo", "ヒビボ")]
        for (index, term) in terms.enumerated() {
            env.vocabulary.add(
                VocabularyEntry(preferred: term.0, spoken: term.1, origin: index == 0 ? .learned : .manual))
        }
    }
}

do {
    try MainActor.assumeIsolated { try run() }
} catch {
    print("Failed: \(error)")
    exit(1)
}
