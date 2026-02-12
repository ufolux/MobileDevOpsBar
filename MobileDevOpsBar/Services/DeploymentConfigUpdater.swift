import Foundation

struct DeploymentUpdateResult {
    let branchName: String
    let pullRequestURL: String
}

enum DeploymentConfigUpdaterError: LocalizedError {
    case missingDeploymentRepo
    case invalidConfigFile
    case missingTag

    var errorDescription: String? {
        switch self {
        case .missingDeploymentRepo:
            return "Deployment repo is not configured."
        case .invalidConfigFile:
            return "Could not update parameters.DEPLOY_TAG.default in .circleci/config.yml."
        case .missingTag:
            return "No tag is available for deployment update."
        }
    }
}

enum DeploymentConfigUpdater {
    static func updateAndOpenPullRequest(
        deploymentRepo: DeploymentRepoConfig,
        workItem: WorkItem,
        token: String
    ) async throws -> DeploymentUpdateResult {
        guard let tag = workItem.latestTag, !tag.isEmpty else {
            throw DeploymentConfigUpdaterError.missingTag
        }

        let branchName = "chore/update-mobile-tag-\(sanitizeBranchComponent(tag))"
        let targetBranch = deploymentRepo.selectedEnvironmentBranch

        try runGit(["-C", deploymentRepo.localPath, "checkout", targetBranch])
        try runGit(["-C", deploymentRepo.localPath, "pull", "origin", targetBranch])
        try runGit(["-C", deploymentRepo.localPath, "checkout", "-B", branchName])

        let configPath = URL(fileURLWithPath: deploymentRepo.localPath)
            .appendingPathComponent(DeploymentRepoConfig.configFilePath)
            .path

        let original = try String(contentsOfFile: configPath, encoding: .utf8)
        let updated = try updateDeployTag(in: original, tag: tag)
        try updated.write(toFile: configPath, atomically: true, encoding: .utf8)

        try runGit(["-C", deploymentRepo.localPath, "add", DeploymentRepoConfig.configFilePath])
        try runGit(["-C", deploymentRepo.localPath, "commit", "-m", "chore: update mobile deployment tag to \(tag)"])
        try runGit(["-C", deploymentRepo.localPath, "push", "-u", "origin", branchName])

        let body = """
        Source ticket: \(workItem.ticketID)
        Source PR: \(workItem.prURL ?? "N/A")
        Updated key: \(DeploymentRepoConfig.deployTagKeyPath)
        New tag: \(tag)
        """

        let created = try await GitHubClient.createPullRequest(
            repoFullName: deploymentRepo.repoFullName,
            title: "chore: update mobile deployment tag to \(tag)",
            body: body,
            head: branchName,
            base: targetBranch,
            token: token
        )

        return DeploymentUpdateResult(branchName: branchName, pullRequestURL: created.htmlURL)
    }

    private static func updateDeployTag(in content: String, tag: String) throws -> String {
        let lines = content.components(separatedBy: .newlines)
        var updatedLines: [String] = []
        var inParameters = false
        var inDeployTag = false
        var replaced = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("parameters:") {
                inParameters = true
                inDeployTag = false
                updatedLines.append(line)
                continue
            }

            if inParameters, line.hasPrefix("  "), trimmed.hasSuffix(":") {
                inDeployTag = trimmed == "DEPLOY_TAG:"
                updatedLines.append(line)
                continue
            }

            if inParameters, inDeployTag, line.hasPrefix("      default:") {
                updatedLines.append("      default: \"\(tag)\"")
                replaced = true
                continue
            }

            if inParameters, !line.hasPrefix("  "), !trimmed.isEmpty {
                inParameters = false
                inDeployTag = false
            }

            updatedLines.append(line)
        }

        guard replaced else {
            throw DeploymentConfigUpdaterError.invalidConfigFile
        }

        return updatedLines.joined(separator: "\n")
    }

    private static func sanitizeBranchComponent(_ input: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        let scalars = input.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars)
    }

    private static func runGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "Unknown git error"
            throw GitBranchServiceError.commandFailed(message)
        }
    }
}
