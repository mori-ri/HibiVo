import AppKit
import Carbon.HIToolbox
import OSLog

/// Follows inserted text in the target's text field for a while so the words the user corrects
/// can be learned into the dictionary.
@MainActor
public protocol CorrectionWatching: AnyObject {
    /// Starts following `inserted`, which was just pasted into the focused field of `target`.
    func watch(inserted: String, target: TargetApplication?)
    /// Stops following and reports what the text became. Called when the next dictation starts.
    func stop()
}

/// Reads the focused text field through the Accessibility API, twice a second, until focus leaves
/// it, the field is sent or cleared, the next dictation starts, or `maximumDuration` passes; then
/// hands the inserted text and its final version to `onFinish`. Polls instead of observing
/// `kAXValueChangedNotification` because Electron apps don't reliably send it.
///
/// Nothing is kept beyond the watch: the field's text lives only in memory until it ends.
/// Terminals and apps that don't expose their text simply yield nothing.
@MainActor
public final class CorrectionWatcher: CorrectionWatching {
    static let pollInterval: Duration = .milliseconds(500)
    static let maximumDuration: Duration = .seconds(45)
    /// Accessibility calls block the main thread until the target answers; don't wait on a busy app.
    static let messagingTimeout: Float = 0.5

    private let isEnabled: @MainActor () -> Bool
    private let onFinish: @MainActor (_ inserted: String, _ edited: String) -> Void
    private var watch: Task<Void, Never>?
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "correction")

    public init(
        isEnabled: @escaping @MainActor () -> Bool,
        onFinish: @escaping @MainActor (_ inserted: String, _ edited: String) -> Void
    ) {
        self.isEnabled = isEnabled
        self.onFinish = onFinish
    }

    public func watch(inserted: String, target: TargetApplication?) {
        stop()
        guard isEnabled(), let target, !inserted.isEmpty, AXIsProcessTrusted(), !IsSecureEventInputEnabled()
        else { return }
        watch = Task { await follow(inserted, in: target.processID) }
    }

    public func stop() {
        watch?.cancel()
        watch = nil
    }

    private func follow(_ inserted: String, in pid: pid_t) async {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        // Electron apps (Slack, VS Code, …) only build their accessibility tree when asked to.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var start: (element: AXUIElement, tracker: InsertedTextTracker)?
        // The tree may take a moment to appear after it is first requested.
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(300)) }
            if let element = Self.focusedElement(of: app), !Self.isSecure(element),
                let value = Self.value(of: element), let caret = Self.caret(of: element),
                let tracker = InsertedTextTracker(value: value, caret: caret, inserted: inserted)
            {
                start = (element, tracker)
                break
            }
        }
        guard let (element, tracker) = start else {
            log.debug("Inserted text not readable in the target; not watching")
            return
        }

        var latest = inserted
        let deadline = ContinuousClock.now + Self.maximumDuration
        while ContinuousClock.now < deadline {
            do { try await Task.sleep(for: Self.pollInterval) } catch { break }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                let focused = Self.focusedElement(of: app), CFEqual(focused, element),
                let value = Self.value(of: element),
                // Gone: sent (chat apps clear the field) or deleted.
                let region = tracker.region(in: value), !region.allSatisfy(\.isWhitespace)
            else { break }
            latest = region
        }
        if latest != inserted { onFinish(inserted, latest) }
    }

    // MARK: - Accessibility

    private static func focusedElement(of app: AXUIElement) -> AXUIElement? {
        guard let value = attribute(kAXFocusedUIElementAttribute, of: app),
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        attribute(kAXSubroleAttribute, of: element) as? String == kAXSecureTextFieldSubrole
    }

    private static func value(of element: AXUIElement) -> String? {
        attribute(kAXValueAttribute, of: element) as? String
    }

    /// The caret position in UTF-16 units; right after a paste it sits at the end of the pasted text.
    private static func caret(of element: AXUIElement) -> Int? {
        guard let value = attribute(kAXSelectedTextRangeAttribute, of: element),
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range), range.length == 0
        else { return nil }
        return range.location
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

/// Where inserted text sits in a field's value, found again after the user edits it. Pure so it
/// can be unit tested.
///
/// The text before and after the insertion must stay as it was; what lies between them is the
/// inserted text as it is now, including anything typed right after it. That extra typing shows
/// up as a pure addition, which `CorrectionExtractor` ignores.
struct InsertedTextTracker {
    let before: String
    let after: String

    /// - Parameter caret: UTF-16 offset just past the pasted text.
    init?(value: String, caret: Int, inserted: String) {
        let text = value as NSString
        let start = caret - (inserted as NSString).length
        guard start >= 0, caret <= text.length,
            text.substring(with: NSRange(location: start, length: caret - start)) == inserted
        else { return nil }
        before = text.substring(to: start)
        after = text.substring(from: caret)
    }

    func region(in value: String) -> String? {
        let text = value as NSString
        let head = (before as NSString).length
        let tail = (after as NSString).length
        // NSString says no string has the empty prefix or suffix.
        guard text.length >= head + tail, before.isEmpty || text.hasPrefix(before),
            after.isEmpty || text.hasSuffix(after)
        else { return nil }
        return text.substring(with: NSRange(location: head, length: text.length - head - tail))
    }
}
