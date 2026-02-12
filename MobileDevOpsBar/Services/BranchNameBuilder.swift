import Foundation

enum BranchNameBuilder {
    static func nextBranchName(for ticketID: String, existingBranches: [String]) -> String {
        let normalizedTicketID = ticketID.uppercased()
        let prefix: String

        if normalizedTicketID.hasPrefix("DE") || normalizedTicketID.hasPrefix("DF") {
            prefix = "fix/starship/\(normalizedTicketID)"
        } else {
            prefix = "feature/starship/\(normalizedTicketID)"
        }

        let nextSequence = nextSequenceNumber(branchPrefix: prefix, existingBranches: existingBranches)
        return "\(prefix)-\(nextSequence)"
    }

    private static func nextSequenceNumber(branchPrefix: String, existingBranches: [String]) -> Int {
        let matchingBranches = existingBranches.filter { $0.hasPrefix(branchPrefix + "-") }
        let maxSequence = matchingBranches.compactMap { branch -> Int? in
            guard let suffix = branch.split(separator: "-").last else { return nil }
            return Int(suffix)
        }.max() ?? 0
        return maxSequence + 1
    }
}
