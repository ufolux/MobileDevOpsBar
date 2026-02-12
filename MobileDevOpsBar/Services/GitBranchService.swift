import Foundation

enum GitBranchServiceError: LocalizedError {
    case missingRepositoryPath
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingRepositoryPath:
            return "Repository path is required to create a branch."
        case .commandFailed(let details):
            return details
        }
    }
}

enum GitBranchService {
    static func createAndCheckoutBranch(repoPath: String, branchName: String) throws {
        guard !repoPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitBranchServiceError.missingRepositoryPath
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repoPath, "checkout", "-b", branchName]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "Unknown git error"
            throw GitBranchServiceError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
