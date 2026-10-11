import Foundation

/// Renders file names from patterns such as `scan-{date:yyyyMMdd}-{ai}`.
enum FileNamer {
    struct Context {
        var date = Date()
        var aiName: String?
        var tag: String?
        var tags: [String] = []
        var pageCount = 0
        var counter = 1
    }

    static let tokenHelp: [(token: String, meaning: String)] = [
        ("{date}", "Scan date, yyyy-MM-dd"),
        ("{date:FORMAT}", "Scan date/time with a custom format, e.g. {date:yyyyMMdd-HHmmss}"),
        ("{time}", "Scan time, HHmmss"),
        ("{ai}", "Apple Intelligence name from libscanline -autoname (fallback: scan)"),
        ("{ai:FALLBACK}", "AI name with a custom fallback"),
        ("{tag}", "Selected tag (AI tag by default)"),
        ("{tags}", "All configured tags joined with '-' ({tags:_} for another separator)"),
        ("{pages}", "Number of pages"),
        ("{counter}", "Running number ({counter:4} pads to 4 digits)"),
    ]

    private static let tokenRegex = try! NSRegularExpression(pattern: #"\{([A-Za-z]+)(?::([^}]*))?\}"#)

    static func usesAI(_ pattern: String) -> Bool {
        matches(in: pattern).contains { $0.token == "ai" }
    }

    static func render(_ pattern: String, _ context: Context) -> String {
        var result = ""
        var last = pattern.startIndex
        for match in matches(in: pattern) {
            result += pattern[last..<match.range.lowerBound]
            result += value(for: match.token, argument: match.argument, context) ?? String(pattern[match.range])
            last = match.range.upperBound
        }
        result += pattern[last...]
        return sanitize(result)
    }

    static func sanitize(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        cleaned.unicodeScalars.removeAll { CharacterSet.controlCharacters.contains($0) }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.lowercased().hasSuffix(".pdf") { cleaned.removeLast(4) }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        while cleaned.utf8.count > 200 { cleaned.removeLast() }
        return cleaned.isEmpty ? "scan" : cleaned
    }

    private static func matches(in pattern: String) -> [(range: Range<String.Index>, token: String, argument: String?)] {
        tokenRegex.matches(in: pattern, range: NSRange(pattern.startIndex..., in: pattern)).compactMap { m in
            guard let range = Range(m.range, in: pattern), let tokenRange = Range(m.range(at: 1), in: pattern) else { return nil }
            let argument = Range(m.range(at: 2), in: pattern).map { String(pattern[$0]) }
            return (range, pattern[tokenRange].lowercased(), argument)
        }
    }

    private static func value(for token: String, argument: String?, _ context: Context) -> String? {
        switch token {
        case "date": return format(context.date, argument ?? "yyyy-MM-dd")
        case "time": return format(context.date, argument ?? "HHmmss")
        case "ai":
            if let ai = context.aiName?.trimmingCharacters(in: .whitespacesAndNewlines), !ai.isEmpty { return ai }
            return argument ?? "scan"
        case "tag": return context.tag ?? ""
        case "tags": return context.tags.joined(separator: argument ?? "-")
        case "pages": return String(context.pageCount)
        case "counter":
            let width = min(max(Int(argument ?? "") ?? 1, 1), 10)
            return String(format: "%0\(width)d", context.counter)
        default: return nil
        }
    }

    private static func format(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
