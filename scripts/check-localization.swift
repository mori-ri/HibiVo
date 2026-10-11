// Checks that every Japanese UI string in HibiVoKit has an English translation, and that every
// translation is still used. Run with `swift scripts/check-localization.swift` (also run by lint.sh).
//
// The Japanese text is the localization key, so a missing entry in
// Resources/en.lproj/Localizable.strings silently shows Japanese to English users.
//
// Skipped: comments, multi-line literals (prompts), files listed in `excludedFiles` (text sent to
// models, written into documents, or used for matching), and lines ending in `// no-l10n`.
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let sources = root.appendingPathComponent("Sources/HibiVoKit")
let stringsFile =
    ProcessInfo.processInfo.environment["L10N_STRINGS"].map { URL(fileURLWithPath: $0) }
    ?? root.appendingPathComponent("Resources/en.lproj/Localizable.strings")

let excludedFiles: Set<String> = [
    "Cleanup/CleanupPromptBuilder.swift",
    "Cleanup/CleanupOutputGuard.swift",
    "Cleanup/TrailingPeriod.swift",
    "Meeting/MarkdownEditing.swift",
    "Meeting/MeetingTranscript.swift",
    "Vocabulary/CorrectionExtractor.swift",
    "Vocabulary/VocabularyReplacer.swift",
]

func isJapanese(_ s: Substring) -> Bool {
    s.unicodeScalars.contains { scalar in
        switch scalar.value {
        case 0x3000...0x30FF, 0x4E00...0x9FFF, 0xFF01...0xFF5E: true
        default: false
        }
    }
}

/// A placeholder for both `\(…)` in Swift and `%@`-style specifiers in .strings.
let hole = "\u{1}"

/// Single-line string literals on a line, with interpolations replaced by `hole`.
func literals(in line: Substring) -> [String] {
    var result: [String] = []
    let chars = Array(line)
    var i = 0
    var current: String? = nil
    while i < chars.count {
        let c = chars[i]
        if var text = current {
            if c == "\\", i + 1 < chars.count {
                if chars[i + 1] == "(" {
                    // Skip the balanced interpolation.
                    var depth = 0
                    var j = i + 1
                    var inString = false
                    while j < chars.count {
                        let d = chars[j]
                        if d == "\"" && chars[j - 1] != "\\" { inString.toggle() }
                        if !inString {
                            if d == "(" { depth += 1 }
                            if d == ")" {
                                depth -= 1
                                if depth == 0 { break }
                            }
                        }
                        j += 1
                    }
                    text += hole
                    i = j + 1
                } else {
                    text += String(c) + String(chars[i + 1])
                    i += 2
                }
                current = text
                continue
            }
            if c == "\"" {
                result.append(text)
                current = nil
            } else {
                text.append(c)
                current = text
            }
        } else {
            // A line comment outside of literals ends the code.
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" { break }
            if c == "\"" {
                if i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" { break }
                current = ""
            }
        }
        i += 1
    }
    return result
}

func normalizedKey(_ key: String) -> String {
    let pattern = try! NSRegularExpression(pattern: "%(\\d+\\$)?(lld|llu|ld|lu|d|u|@|lf|f|\\.\\d+f|\\.\\d+lf)")
    let ns = key.replacingOccurrences(of: "%%", with: "\u{2}")
    let replaced = pattern.stringByReplacingMatches(
        in: ns, range: NSRange(ns.startIndex..., in: ns), withTemplate: hole)
    return replaced.replacingOccurrences(of: "\u{2}", with: "%")
}

func holes(_ s: String) -> Int { s.components(separatedBy: hole).count - 1 }

// Parse `"key" = "value";` lines.
var translations: [String: (key: String, value: String)] = [:]
var problems: [String] = []
let stringsText = (try? String(contentsOf: stringsFile, encoding: .utf8)) ?? ""
let entry = try! NSRegularExpression(pattern: #"^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$"#)
for line in stringsText.split(separator: "\n") {
    let s = String(line)
    guard let m = entry.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
    let key = String(s[Range(m.range(at: 1), in: s)!])
    let value = String(s[Range(m.range(at: 2), in: s)!])
    let normalized = normalizedKey(key)
    if translations[normalized] != nil { problems.append("duplicate key: \"\(key)\"") }
    translations[normalized] = (key, value)
    if holes(normalized) != holes(normalizedKey(value)) {
        problems.append("placeholder count differs: \"\(key)\" = \"\(value)\"")
    }
    if isJapanese(Substring(value)) { problems.append("untranslated value: \"\(key)\" = \"\(value)\"") }
}

var used = Set<String>()
let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
    .compactMap { $0 as? URL }
    .filter { $0.pathExtension == "swift" }
    .sorted { $0.path < $1.path }
for file in files {
    let relative = String(file.path.dropFirst(sources.path.count + 1))
    if excludedFiles.contains(relative) { continue }
    let text = try! String(contentsOf: file, encoding: .utf8)
    var inMultiline = false
    for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.components(separatedBy: "\"\"\"").count % 2 == 0 { inMultiline.toggle() }
        if inMultiline || trimmed.hasPrefix("\"\"\"") || trimmed.hasPrefix("//") { continue }
        if trimmed.hasSuffix("// no-l10n") { continue }
        for literal in literals(in: line) where isJapanese(Substring(literal)) {
            if translations[literal] != nil {
                used.insert(literal)
            } else {
                problems.append("Sources/HibiVoKit/\(relative):\(number + 1): no translation for \"\(literal)\"")
            }
        }
    }
}
for (normalized, entry) in translations where !used.contains(normalized) {
    problems.append("unused translation: \"\(entry.key)\"")
}

if problems.isEmpty {
    print("Localization OK (\(translations.count) strings)")
} else {
    for problem in problems.sorted() { print(problem) }
    exit(1)
}
