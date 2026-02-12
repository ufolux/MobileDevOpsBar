import Foundation

enum WorkflowTagResolver {
    static func resolveTag(
        repoFullName: String,
        workflowIdentifier: String,
        branch: String,
        token: String
    ) async throws -> (tag: String, runURL: String) {
        guard let run = try await GitHubClient.fetchLatestWorkflowRun(
            repoFullName: repoFullName,
            workflowIdentifier: workflowIdentifier,
            branch: branch,
            token: token
        ) else {
            throw GitHubClientError.invalidResponse
        }

        let jobs = try await GitHubClient.fetchJobs(repoFullName: repoFullName, runID: run.id, token: token)
        guard let buildAndPublish = jobs.first(where: { $0.name == "build-and-publish" }) else {
            throw GitHubClientError.invalidResponse
        }

        let logs = try await GitHubClient.fetchJobLogs(repoFullName: repoFullName, jobID: buildAndPublish.id, token: token)
        guard let tag = extractTag(fromLogs: logs) else {
            throw GitHubClientError.missingTagInLogs
        }

        return (tag, run.htmlURL)
    }

    private static func extractTag(fromLogs logs: String) -> String? {
        guard logs.contains("Push Artifact (Gated)") else {
            return nil
        }

        let lines = logs.components(separatedBy: .newlines)
        for line in lines.reversed() {
            guard let range = line.range(of: "New Tag is ") else { continue }
            let tag = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty {
                return tag
            }
        }
        return nil
    }
}
