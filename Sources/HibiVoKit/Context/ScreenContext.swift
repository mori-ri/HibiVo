import Foundation

/// Text around the place the dictation is pasted, read when recording stops and given to cleanup
/// as reference only (the mail being replied to, the thread above a reply box). Never stored.
public struct ScreenContext: Equatable, Sendable {
    /// The window or page title, usually the subject.
    public var title: String
    /// The quoted mail after the caret, or else the visible text just before the field.
    public var body: String
    /// What the user already wrote before the caret.
    public var draft: String

    public init(title: String = "", body: String = "", draft: String = "") {
        self.title = title
        self.body = body
        self.draft = draft
    }

    public var isEmpty: Bool { title.isEmpty && body.isEmpty && draft.isEmpty }
}

/// Turns what the accessibility API exposes into a `ScreenContext`. Pure so it can be unit tested;
/// `ScreenContextReader` does the reading.
public enum ScreenContextExtractor {
    /// One piece of static text, with the screen y of its top edge when known.
    public struct Piece: Equatable, Sendable {
        public var text: String
        public var top: Double?

        public init(_ text: String, top: Double? = nil) {
            self.text = text
            self.top = top
        }
    }

    static let bodyLimit = 3000
    static let draftLimit = 1000
    static let titleLimit = 200

    /// - Parameters:
    ///   - fieldValue: The focused field's text.
    ///   - caret: The caret position in `fieldValue`, in UTF-16 units.
    ///   - screen: Static text before the field in document order; nil when the walk didn't reach
    ///     the field, so the text isn't known to be what precedes it.
    public static func make(title: String, fieldValue: String?, caret: Int?, screen: [Piece]?) -> ScreenContext {
        var context = ScreenContext(title: String(clean(title).prefix(titleLimit)))
        if let fieldValue {
            let utf16 = Array(fieldValue.utf16)
            let split = min(max(caret ?? utf16.count, 0), utf16.count)
            context.draft = String(clean(String(decoding: utf16[..<split], as: UTF16.self)).suffix(draftLimit))
            // Outlook and Mail put the quoted mail after the caret, newest first: keep its start.
            context.body = String(clean(String(decoding: utf16[split...], as: UTF16.self)).prefix(bodyLimit))
        }
        if context.body.isEmpty, let screen {
            // Gmail and chat apps show the thread above the reply box: keep what's nearest to it.
            context.body = String(lines(screen).joined(separator: "\n").suffix(bodyLimit))
        }
        return context
    }

    /// Joins pieces on the same visual line ("To" + "自分") and drops pieces with nothing to read.
    static func lines(_ pieces: [Piece]) -> [String] {
        var lines: [(text: String, top: Double?)] = []
        for piece in pieces {
            let text = clean(piece.text)
            guard !text.isEmpty else { continue }
            if let top = piece.top, let last = lines.last, let lastTop = last.top, abs(lastTop - top) < 2 {
                lines[lines.count - 1].text += " " + text
            } else {
                lines.append((text, piece.top))
            }
        }
        return lines.map(\.text)
    }

    /// Web pages pad text with zero-width characters and object replacement characters, and icon
    /// fonts show up as private-use characters.
    static func clean(_ text: String) -> String {
        let visible = String(
            String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .privateUse }))
        return visible.trimmingCharacters(in: invisible)
    }

    private static let invisible = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{FFFC}"))
}
