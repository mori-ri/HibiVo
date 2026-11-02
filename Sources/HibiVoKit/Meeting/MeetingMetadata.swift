import Foundation

/// The title and tags the user gives a meeting while it runs. Pure so it can be unit tested.
///
/// They are saved as YAML front matter at the top of the transcript and the minutes, the form notes
/// apps (Obsidian and others) read as properties, so the files stay the source of truth: the archive
/// reads them back from there.
public struct MeetingMetadata: Codable, Hashable, Sendable {
    /// Most characters a title keeps.
    static let titleLimit = 100
    /// Most characters a tag keeps.
    static let tagLimit = 40
    /// Most tags a meeting keeps.
    static let tagCountLimit = 20
    /// How much of a file is read to find its front matter.
    static let headLength = 4096

    public var title: String
    public var tags: [String]

    public init(title: String = "", tags: [String] = []) {
        self.title = Self.normalizedTitle(title)
        var normalized: [String] = []
        for tag in tags { normalized = Self.adding(tag, to: normalized) }
        self.tags = normalized
    }

    public var isEmpty: Bool { title.isEmpty && tags.isEmpty }

    // MARK: - Input

    /// One line, trimmed and capped. Line breaks become spaces so the title stays a heading.
    public static func normalizedTitle(_ title: String) -> String {
        let oneLine = title.components(separatedBy: .newlines).joined(separator: " ")
        let cleaned = String(String.UnicodeScalarView(oneLine.unicodeScalars.filter { !isControl($0) }))
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(titleLimit)).trimmingCharacters(in: .whitespaces)
    }

    /// A tag as notes apps accept it: no `#`, no spaces or separators, capped. nil when nothing is left.
    public static func normalizedTag(_ tag: String) -> String? {
        let cleaned = String(
            String.UnicodeScalarView(
                tag.unicodeScalars.filter {
                    !isControl($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
                        && !separators.contains($0) && !"#\"'[]{}".unicodeScalars.contains($0)
                }))
        let tag = String(cleaned.prefix(tagLimit))
        return tag.isEmpty ? nil : tag
    }

    /// `tags` with `tag` added at the end, unless it is empty, already there (ignoring case and width)
    /// or the list is full.
    public static func adding(_ tag: String, to tags: [String]) -> [String] {
        guard let tag = normalizedTag(tag), tags.count < tagCountLimit,
            !tags.contains(where: { matchKey($0) == matchKey(tag) })
        else { return tags }
        return tags + [tag]
    }

    /// Splits what was typed into the tag field. While typing, only a comma or a space ends a tag: an
    /// input method composes `、` with the word before it, so splitting there would cut into the
    /// conversion. Return (`isFinished`) also splits at `、` and keeps nothing in the field.
    /// - Returns: The tags to add, and what stays in the field.
    public static func splitTagInput(_ input: String, isFinished: Bool) -> (tags: [String], remainder: String) {
        let end: String.Index
        if isFinished {
            end = input.endIndex
        } else {
            guard let last = input.lastIndex(where: { $0 == "," || $0.isWhitespace }) else { return ([], input) }
            end = last
        }
        let tags = input[..<end].split { $0.isWhitespace || isSeparator($0) }.compactMap { normalizedTag(String($0)) }
        return (tags, end == input.endIndex ? "" : String(input[input.index(after: end)...]))
    }

    /// Tags used in earlier meetings, most recent first, leaving out those already added.
    /// - Parameter records: Newest first, as the archive lists them.
    public static func recentTags(_ records: [MeetingRecord], excluding: [String] = [], limit: Int = 8) -> [String] {
        var seen = Set(excluding.map(matchKey))
        var result: [String] = []
        for record in records {
            for tag in record.metadata.tags {
                guard seen.insert(matchKey(tag)).inserted else { continue }
                result.append(tag)
                if result.count == limit { return result }
            }
        }
        return result
    }

    /// Commas (half and full width) and the Japanese comma separate tags, like spaces.
    private static let separators = CharacterSet(charactersIn: ",、，")  // no-l10n

    private static func isSeparator(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { separators.contains($0) }
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar) && !CharacterSet.newlines.contains(scalar)
    }

    private static func matchKey(_ tag: String) -> String {
        tag.precomposedStringWithCompatibilityMapping.lowercased()
    }

    // MARK: - Front matter

    /// The YAML front matter, ending with its closing `---`; nil when there is nothing to write.
    public var frontMatter: String? {
        guard !isEmpty else { return nil }
        var lines = ["---"]
        if !title.isEmpty { lines.append("title: \(Self.quoted(title))") }
        if !tags.isEmpty {
            lines.append("tags:")
            lines += tags.map { "  - \(Self.quoted($0))" }
        }
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    /// Reads the title and tags from the front matter at the start of `text`. Accepts what this type
    /// writes and the common forms a notes app may rewrite it to (flow lists, unquoted values).
    public static func parse(_ text: String) -> MeetingMetadata {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if let first = lines.first, first.hasPrefix("\u{FEFF}") { lines[0] = String(first.dropFirst()) }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return MeetingMetadata() }

        var title = ""
        var tags: [String] = []
        var inTagList = false
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                return MeetingMetadata(title: title, tags: tags)
            }
            if inTagList, trimmed.hasPrefix("-") {
                tags.append(unquoted(String(trimmed.dropFirst())))
                continue
            }
            inTagList = false
            // Only top-level keys; nested ones are indented.
            guard line.first?.isWhitespace == false, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "title":
                title = unquoted(value)
            case "tags", "tag":
                if value.isEmpty {
                    inTagList = true
                } else if value.hasPrefix("[") {
                    tags += flowList(value)
                } else {
                    tags += unquoted(value).split { $0 == "," || $0 == " " }.map(String.init)
                }
            default:
                continue
            }
        }
        // No closing line: not front matter after all.
        return MeetingMetadata()
    }

    /// Reads the front matter of a saved meeting file from its first few kilobytes.
    static func read(from url: URL) -> MeetingMetadata {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return MeetingMetadata() }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headLength) else { return MeetingMetadata() }
        // A multi-byte character cut at the end turns into U+FFFD, far below the front matter.
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// A double-quoted YAML string, so a title like `議題: 予算` or `#1` stays a plain string.
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The scalar a YAML value holds: unquoted, with escapes in double quotes and `''` in single quotes undone.
    static func unquoted(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            var result = ""
            var escaping = false
            for character in value.dropFirst().dropLast() {
                if escaping {
                    switch character {
                    case "n": result.append(" ")
                    case "t": result.append(" ")
                    default: result.append(character)
                    }
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else {
                    result.append(character)
                }
            }
            return result
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        // A plain scalar may end with a comment.
        if let comment = value.range(of: " #") { return String(value[..<comment.lowerBound]) }
        return value
    }

    /// The items of a flow list such as `[a, "b, c"]`.
    static func flowList(_ value: String) -> [String] {
        var inner = Substring(value.trimmingCharacters(in: .whitespaces))
        if inner.hasPrefix("[") { inner = inner.dropFirst() }
        if let end = inner.lastIndex(of: "]") { inner = inner[..<end] }
        var items: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        for character in inner {
            current.append(character)
            if escaping {
                escaping = false
            } else if let open = quote {
                if character == "\\" && open == "\"" {
                    escaping = true
                } else if character == open {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "," {
                current.removeLast()
                items.append(unquoted(current))
                current = ""
            }
        }
        items.append(unquoted(current))
        return items.filter { !$0.isEmpty }
    }
}
