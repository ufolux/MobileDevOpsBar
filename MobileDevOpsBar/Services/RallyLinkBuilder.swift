import Foundation

enum RallyLinkBuilder {
    static func url(template: String, ticketID: String) -> URL? {
        let trimmedTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTemplate.isEmpty else { return nil }

        let replaced = trimmedTemplate
            .replacingOccurrences(of: "{ticketnumber}", with: ticketID, options: .caseInsensitive)
            .replacingOccurrences(of: "{ticketNumber}", with: ticketID)

        return URL(string: replaced)
    }
}
