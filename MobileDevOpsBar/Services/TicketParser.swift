import Foundation

enum TicketParser {
    private static let pattern = #"\b(?:US|DE)\d+\b"#

    static func parseTickets(from rawText: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsRange = NSRange(rawText.startIndex..., in: rawText)
        let matches = regex.matches(in: rawText, options: [], range: nsRange)

        var seen = Set<String>()
        var results: [String] = []

        for match in matches {
            guard let range = Range(match.range, in: rawText) else { continue }
            let ticket = rawText[range].uppercased()
            if seen.insert(ticket).inserted {
                results.append(ticket)
            }
        }

        return results
    }
}
