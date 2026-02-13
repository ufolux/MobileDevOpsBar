import Foundation

struct WebDeploymentUpdateResult {
    let branchName: String
    let pullRequestURL: String
    let updatedFileCount: Int
}

enum WebWorkflowServiceError: LocalizedError {
    case missingModules
    case missingEnvironments
    case missingVersions([String])
    case noFilesUpdated
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .missingModules:
            return "Select at least one module."
        case .missingEnvironments:
            return "Select at least one environment."
        case .missingVersions(let modules):
            return "Missing version values for: \(modules.joined(separator: ", "))."
        case .noFilesUpdated:
            return "No deployment files were updated. Check module/environment values and repository structure."
        case .invalidResponse:
            return "Invalid response from GitHub API."
        case .requestFailed(let statusCode):
            return "GitHub API request failed with status code \(statusCode)."
        }
    }
}

enum WebWorkflowService {
    private static let maxRunsToCheck = 50
    private static let imagePattern = #"CONTAINER_IMAGE_INFO:\s+cvsh\.jfrog\.io/[^/]+/[^/]+/[^/]+/[^/]+/([^:]+):([^\s]+)"#
    private static let dockerTagPattern = #"(dockerImageTag:\s+)[^\s]+"#

    static func findLatestVersions(
        repoFullName: String,
        branch: String,
        modules: [String],
        token: String
    ) async throws -> [String: String] {
        let targetModules = Set(modules.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !targetModules.isEmpty else {
            throw WebWorkflowServiceError.missingModules
        }

        let runs = try await fetchWorkflowRuns(repoFullName: repoFullName, branch: branch, token: token)
        var foundVersions: [String: String] = [:]

        for (index, run) in runs.enumerated() {
            if index >= maxRunsToCheck { break }

            let remaining = targetModules.subtracting(foundVersions.keys)
            if remaining.isEmpty { break }

            let jobs = try await fetchJobs(repoFullName: repoFullName, runID: run.id, token: token)
                .filter { job in
                    job.name.localizedCaseInsensitiveContains("Docker Publish") ||
                    job.name.localizedCaseInsensitiveContains("Container Scan")
                }

            for job in jobs {
                let logs = try await fetchJobLogs(repoFullName: repoFullName, jobID: job.id, token: token)
                let parsed = extractImageVersions(from: logs, modules: remaining)
                for (module, version) in parsed where foundVersions[module] == nil {
                    foundVersions[module] = version
                }
            }
        }

        return foundVersions
    }

    static func createWebDeploymentPullRequest(
        deploymentRepoFullName: String,
        baseBranch: String,
        sourceRepoFullName: String,
        sourceBranch: String,
        modules: [String],
        environments: [String],
        versions: [String: String],
        prTitle: String,
        token: String,
        ticketID: String,
        sourcePRURL: String?
    ) async throws -> WebDeploymentUpdateResult {
        let cleanModules = modules.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let cleanEnvironments = environments.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        guard !cleanModules.isEmpty else { throw WebWorkflowServiceError.missingModules }
        guard !cleanEnvironments.isEmpty else { throw WebWorkflowServiceError.missingEnvironments }

        let missingVersions = cleanModules.filter {
            let value = versions[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty
        }
        guard missingVersions.isEmpty else {
            throw WebWorkflowServiceError.missingVersions(missingVersions)
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let branchName = "chore/update-web-tags-\(sanitizeBranchPart(ticketID.lowercased()))-\(timestamp.prefix(13))"

        let baseSHA = try await fetchBranchSHA(repoFullName: deploymentRepoFullName, branch: baseBranch, token: token)
        try await createBranch(repoFullName: deploymentRepoFullName, newBranch: branchName, baseSHA: baseSHA, token: token)

        var updatedFileCount = 0

        for module in cleanModules {
            let cleanedModuleName = module.replacingOccurrences(of: "-", with: "")
            let version = versions[module]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            for env in cleanEnvironments {
                let path = "mah-ui-web-\(cleanedModuleName)-svc/mah-ui-web-\(env)/values/v1.yaml"
                do {
                    let file = try await fetchFile(repoFullName: deploymentRepoFullName, path: path, ref: branchName, token: token)
                    let updated = replaceDockerTag(in: file.content, version: version)
                    guard updated != file.content else { continue }

                    let message = "chore: update dockerImageTag for \(module)/\(env) to \(version)"
                    try await updateFile(
                        repoFullName: deploymentRepoFullName,
                        path: path,
                        branch: branchName,
                        newContent: updated,
                        sha: file.sha,
                        message: message,
                        token: token
                    )
                    updatedFileCount += 1
                } catch {
                    continue
                }
            }
        }

        guard updatedFileCount > 0 else {
            throw WebWorkflowServiceError.noFilesUpdated
        }

        let body = """
        Automated web deployment updates.

        Ticket: \(ticketID)
        Source Repo: \(sourceRepoFullName)
        Source Branch: \(sourceBranch)
        Source PR: \(sourcePRURL ?? "N/A")
        Updated Files: \(updatedFileCount)
        """

        let prURL = try await createPullRequest(
            repoFullName: deploymentRepoFullName,
            title: prTitle,
            body: body,
            head: branchName,
            base: baseBranch,
            token: token
        )

        return WebDeploymentUpdateResult(branchName: branchName, pullRequestURL: prURL, updatedFileCount: updatedFileCount)
    }

    private static func extractImageVersions(from logs: String, modules: Set<String>) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: imagePattern) else { return [:] }
        let range = NSRange(logs.startIndex..., in: logs)
        let matches = regex.matches(in: logs, range: range)
        var output: [String: String] = [:]

        for match in matches {
            guard let moduleRange = Range(match.range(at: 1), in: logs),
                  let versionRange = Range(match.range(at: 2), in: logs) else {
                continue
            }
            let module = String(logs[moduleRange])
            let version = String(logs[versionRange])
            guard modules.contains(module), output[module] == nil else { continue }
            output[module] = version
        }

        return output
    }

    private static func replaceDockerTag(in content: String, version: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: dockerTagPattern) else { return content }
        let range = NSRange(content.startIndex..., in: content)
        let replacement = "$1\(version)"
        return regex.stringByReplacingMatches(in: content, range: range, withTemplate: replacement)
    }

    private static func sanitizeBranchPart(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(mapped)
    }

    private static func fetchWorkflowRuns(repoFullName: String, branch: String, token: String) async throws -> [WorkflowRun] {
        var components = URLComponents(string: "https://api.github.com/repos/\(repoFullName)/actions/runs")
        components?.queryItems = [
            URLQueryItem(name: "branch", value: branch),
            URLQueryItem(name: "per_page", value: "100")
        ]
        guard let url = components?.url else { throw WebWorkflowServiceError.invalidResponse }

        let response: WorkflowRunsResponse = try await request(url: url, token: token, method: "GET")
        return response.workflowRuns
    }

    private static func fetchJobs(repoFullName: String, runID: Int, token: String) async throws -> [WorkflowJob] {
        let url = URL(string: "https://api.github.com/repos/\(repoFullName)/actions/runs/\(runID)/jobs?per_page=100")!
        let response: JobsResponse = try await request(url: url, token: token, method: "GET")
        return response.jobs
    }

    private static func fetchJobLogs(repoFullName: String, jobID: Int, token: String) async throws -> String {
        let url = URL(string: "https://api.github.com/repos/\(repoFullName)/actions/jobs/\(jobID)/logs")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("MobileDevOpsBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebWorkflowServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebWorkflowServiceError.requestFailed(httpResponse.statusCode)
        }

        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func fetchBranchSHA(repoFullName: String, branch: String, token: String) async throws -> String {
        let escapedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        let url = URL(string: "https://api.github.com/repos/\(repoFullName)/git/ref/heads/\(escapedBranch)")!
        let response: GitRefResponse = try await request(url: url, token: token, method: "GET")
        return response.object.sha
    }

    private static func createBranch(repoFullName: String, newBranch: String, baseSHA: String, token: String) async throws {
        let url = URL(string: "https://api.github.com/repos/\(repoFullName)/git/refs")!
        let payload = CreateGitRefRequest(ref: "refs/heads/\(newBranch)", sha: baseSHA)

        do {
            _ = try await request(url: url, token: token, method: "POST", body: payload) as GitRefResponse
        } catch WebWorkflowServiceError.requestFailed(let code) where code == 422 {
            return
        }
    }

    private static func fetchFile(repoFullName: String, path: String, ref: String, token: String) async throws -> (sha: String, content: String) {
        var components = URLComponents(string: "https://api.github.com/repos/\(repoFullName)/contents/\(path)")
        components?.queryItems = [URLQueryItem(name: "ref", value: ref)]
        guard let url = components?.url else { throw WebWorkflowServiceError.invalidResponse }

        let response: RepositoryContentResponse = try await request(url: url, token: token, method: "GET")
        let normalized = response.content.replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: normalized),
              let text = String(data: data, encoding: .utf8) else {
            throw WebWorkflowServiceError.invalidResponse
        }
        return (sha: response.sha, content: text)
    }

    private static func updateFile(
        repoFullName: String,
        path: String,
        branch: String,
        newContent: String,
        sha: String,
        message: String,
        token: String
    ) async throws {
        let url = URL(string: "https://api.github.com/repos/\(repoFullName)/contents/\(path)")!
        let payload = UpdateContentRequest(
            message: message,
            content: Data(newContent.utf8).base64EncodedString(),
            sha: sha,
            branch: branch
        )
        _ = try await request(url: url, token: token, method: "PUT", body: payload) as UpdateContentResponse
    }

    private static func createPullRequest(
        repoFullName: String,
        title: String,
        body: String,
        head: String,
        base: String,
        token: String
    ) async throws -> String {
        let url = URL(string: "https://api.github.com/repos/\(repoFullName)/pulls")!
        let payload = CreatePullRequestRequest(title: title, body: body, head: head, base: base)
        let response: CreatePullRequestResponse = try await request(url: url, token: token, method: "POST", body: payload)
        return response.htmlURL
    }

    private static func request<T: Decodable>(
        url: URL,
        token: String,
        method: String
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("MobileDevOpsBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebWorkflowServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebWorkflowServiceError.requestFailed(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func request<T: Decodable, Payload: Encodable>(
        url: URL,
        token: String,
        method: String,
        body: Payload?
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("MobileDevOpsBar", forHTTPHeaderField: "User-Agent")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebWorkflowServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebWorkflowServiceError.requestFailed(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct WorkflowRunsResponse: Decodable {
    let workflowRuns: [WorkflowRun]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

private struct WorkflowRun: Decodable {
    let id: Int
}

private struct JobsResponse: Decodable {
    let jobs: [WorkflowJob]
}

private struct WorkflowJob: Decodable {
    let id: Int
    let name: String
}

private struct GitRefResponse: Decodable {
    let object: GitObject
}

private struct GitObject: Decodable {
    let sha: String
}

private struct CreateGitRefRequest: Encodable {
    let ref: String
    let sha: String
}

private struct RepositoryContentResponse: Decodable {
    let sha: String
    let content: String
}

private struct UpdateContentRequest: Encodable {
    let message: String
    let content: String
    let sha: String
    let branch: String
}

private struct UpdateContentResponse: Decodable {
    let content: UpdatedContent
}

private struct UpdatedContent: Decodable {
    let sha: String
}

private struct CreatePullRequestRequest: Encodable {
    let title: String
    let body: String
    let head: String
    let base: String
}

private struct CreatePullRequestResponse: Decodable {
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case htmlURL = "html_url"
    }
}
