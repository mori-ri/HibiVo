import ApplicationServices
import Carbon.HIToolbox
import Foundation

public protocol ScreenContextReading: Sendable {
    /// The text around the focused field of the app, or nil when there is nothing to read
    /// (no field, a password field, no permission).
    func read(processID: pid_t) async -> ScreenContext?
}

/// Reads `ScreenContext` from the target app with the accessibility API, off the main actor.
///
/// Tried in order: the field's own text split at the caret (Outlook and Mail quote the mail after
/// it), then the static text before the field inside the nearest main landmark or web area (Gmail
/// shows the thread above the reply box). Side panels and tab strips sit outside that container.
public struct ScreenContextReader: ScreenContextReading {
    /// Reading runs while STT finishes, so it mostly costs nothing; past this it gives up.
    static let budget: TimeInterval = 0.3
    static let maxNodes = 3000
    /// Per call. A busy app answering slowly shouldn't hold up the paste.
    static let messagingTimeout: Float = 0.2

    public init() {}

    public func read(processID: pid_t) async -> ScreenContext? {
        await Task.detached(priority: .userInitiated) { Self.readNow(processID: processID) }.value
    }

    static func readNow(processID: pid_t) -> ScreenContext? {
        // Password fields turn on Secure Input; nothing near them should leave the Mac.
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let field = element(app, kAXFocusedUIElementAttribute),
            string(field, kAXSubroleAttribute) != kAXSecureTextFieldSubrole
        else { return nil }

        let deadline = Date().addingTimeInterval(budget)
        var caret: Int?
        if let value = attribute(field, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) { caret = range.location }
        }
        let fieldValue = string(field, kAXValueAttribute)

        let (container, webArea) = containers(of: field)
        var walk = Walk(field: field, deadline: deadline)
        if let container { walk.collect(container) }
        // Browsers cut the window title short; the page's web area has it in full.
        let title =
            webArea.flatMap { string($0, kAXTitleAttribute) }
            ?? element(app, kAXFocusedWindowAttribute).flatMap { string($0, kAXTitleAttribute) } ?? ""

        let context = ScreenContextExtractor.make(
            title: title, fieldValue: fieldValue, caret: caret, screen: walk.reachedField ? walk.pieces : nil)
        return context.isEmpty ? nil : context
    }

    /// The nearest main landmark, else web area, else window, and the nearest web area for the title.
    private static func containers(of field: AXUIElement) -> (container: AXUIElement?, webArea: AXUIElement?) {
        var webArea: AXUIElement?
        var current = element(field, kAXParentAttribute)
        while let node = current {
            if string(node, kAXSubroleAttribute) == "AXLandmarkMain" {
                return (node, webArea ?? nearestWebArea(above: node))
            }
            let role = string(node, kAXRoleAttribute)
            if role == "AXWebArea", webArea == nil { webArea = node }
            if role == kAXWindowRole { return (webArea ?? node, webArea) }
            current = element(node, kAXParentAttribute)
        }
        return (webArea, webArea)
    }

    private static func nearestWebArea(above node: AXUIElement) -> AXUIElement? {
        var current = element(node, kAXParentAttribute)
        while let ancestor = current {
            let role = string(ancestor, kAXRoleAttribute)
            if role == "AXWebArea" { return ancestor }
            if role == kAXWindowRole { return nil }
            current = element(ancestor, kAXParentAttribute)
        }
        return nil
    }

    /// Walks the container in document order, collecting static text until it reaches the field.
    private struct Walk {
        let field: AXUIElement
        let deadline: Date
        var pieces: [ScreenContextExtractor.Piece] = []
        var nodes = 0
        var reachedField = false
        var stopped = false

        /// Controls whose text is UI chrome, not content. Their subtrees are skipped.
        static let chromeRoles: Set<String> = [
            kAXButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole, kAXCheckBoxRole, kAXRadioButtonRole,
            kAXMenuBarRole, kAXMenuRole, kAXToolbarRole, kAXScrollBarRole, kAXTextFieldRole, kAXTextAreaRole,
            kAXComboBoxRole, kAXSliderRole,
        ]

        init(field: AXUIElement, deadline: Date) {
            self.field = field
            self.deadline = deadline
        }

        mutating func collect(_ node: AXUIElement) {
            guard !reachedField, !stopped else { return }
            if CFEqual(node, field) {
                reachedField = true
                return
            }
            guard nodes < ScreenContextReader.maxNodes, Date() < deadline else {
                stopped = true
                return
            }
            nodes += 1
            let info = ScreenContextReader.info(node)
            if let role = info.role, Self.chromeRoles.contains(role) { return }
            if info.role == kAXStaticTextRole {
                if let text = info.value { pieces.append(.init(text, top: info.top)) }
                return  // Its children repeat the same text.
            }
            for child in info.children {
                collect(child)
                if reachedField || stopped { return }
            }
        }
    }

    // MARK: - Accessibility

    private struct NodeInfo {
        var role: String?
        var value: String?
        var top: Double?
        var children: [AXUIElement] = []
    }

    /// Role, value, position and children in one round trip; Chromium answers each call over IPC,
    /// so asking one attribute at a time adds up over a few hundred nodes.
    private static func info(_ node: AXUIElement) -> NodeInfo {
        let names = [kAXRoleAttribute, kAXValueAttribute, kAXPositionAttribute, kAXChildrenAttribute] as CFArray
        var values: CFArray?
        guard
            AXUIElementCopyMultipleAttributeValues(node, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
                == .success,
            let array = values as? [CFTypeRef], array.count == 4
        else { return NodeInfo() }
        // Missing attributes come back as AXValue errors, which the casts below turn into nil.
        var top: Double?
        if CFGetTypeID(array[2]) == AXValueGetTypeID() {
            var point = CGPoint.zero
            if AXValueGetValue(unsafeDowncast(array[2], to: AXValue.self), .cgPoint, &point) { top = point.y }
        }
        return NodeInfo(
            role: array[0] as? String, value: array[1] as? String, top: top, children: elements(in: array[3]))
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return prepared(unsafeDowncast(value, to: AXUIElement.self))
    }

    private static func elements(in value: CFTypeRef) -> [AXUIElement] {
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return (value as! [CFTypeRef]).compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? prepared(unsafeDowncast($0, to: AXUIElement.self)) : nil
        }
    }

    /// The timeout set on the app element doesn't carry over to the elements it returns.
    private static func prepared(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }
}
