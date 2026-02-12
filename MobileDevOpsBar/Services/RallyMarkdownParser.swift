import Foundation

struct RallyEntry {
    let ticketNumber: String
    let url: URL
    let markdown: String
}

enum RallyMarkdownParser {
    private static let pattern = #"^\s*\[([^\]]+)\]\(([^\)]+)\)\s*$"#

    static func parseEntries(from rawText: String) -> (entries: [RallyEntry], invalidLines: [String]) {
        let lines = rawText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var entries: [RallyEntry] = []
        var invalidLines: [String] = []

        for line in lines {
            guard let entry = parseEntry(from: line) else {
                invalidLines.append(line)
                continue
            }
            entries.append(entry)
        }

        return (entries, invalidLines)
    }

    static func parseEntry(from markdown: String) -> RallyEntry? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(markdown.startIndex..., in: markdown)
        guard let match = regex.firstMatch(in: markdown, options: [], range: range),
              let ticketRange = Range(match.range(at: 1), in: markdown),
              let urlRange = Range(match.range(at: 2), in: markdown)
        else {
            return nil
        }

        let ticketNumber = markdown[ticketRange].trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = markdown[urlRange].trimmingCharacters(in: .whitespacesAndNewlines)

        guard !ticketNumber.isEmpty,
              let url = URL(string: urlString),
              let scheme = url.scheme,
              !scheme.isEmpty
        else {
            return nil
        }

        return RallyEntry(ticketNumber: ticketNumber, url: url, markdown: markdown)
    }
}
