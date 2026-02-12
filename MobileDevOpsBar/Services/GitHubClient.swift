import Foundation

struct PullRequestSummary {
    let number: Int
    let url: String
    let state: String
    let mergedAt: Date?
    let headSHA: String
    let baseBranch: String
}

struct PullRequestSignals {
    let reviewRequestedCount: Int
    let issueCommentCount: Int
    let reviewCommentCount: Int
}

struct WorkflowRunSummary {
    let id: Int
    let htmlURL: String
}

struct JobSummary {
    let id: Int
    let name: String
}

struct CreatedPullRequest {
    let htmlURL: String
}

enum GitHubClientError: LocalizedError {
    case invalidRepositoryName
    case invalidResponse
    case requestFailed(Int)
    case missingTagInLogs

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryName:
            return "Invalid repository full name. Expected owner/repo."
        case .invalidResponse:
            return "Invalid response from GitHub API."
        case .requestFailed(let code):
            return "GitHub API request failed with status code \(code)."
        case .missingTagInLogs:
            return "Could not find 'New Tag is {tag}' in workflow logs."
        }
    }
}

enum GitHubClient {
    static func fetchPullRequest(repoFullName: String, headBranch: String, token: String) async throws -> PullRequestSummary? {
        let owner = try owner(from: repoFullName)
        var components = URLComponents(string: "https://api.github.com/repos/\(repoFullName)/pulls")
        components?.queryItems = [
            URLQueryItem(name: "head", value: "\(owner):\(headBranch)"),
            URLQueryItem(name: "state", value: "all"),
            URLQueryItem(name: "per_page", value: "1"),
        ]

        guard let url = components?.url else {
            throw GitHubClientError.invalidResponse
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response: [PullRequestResponse] = try await request(url: url, token: token, decodeAs: [PullRequestResponse].self, decoder: decoder)
        guard let first = response.first else {
            return nil
        }

        return PullRequestSummary(
            number: first.number,
            url: first.htmlURL,
            state: first.state,
            mergedAt: first.mergedAt,
            headSHA: first.head.sha,
            baseBranch: first.base.ref
        )
    }

    static func fetchCheckState(repoFullName: String, commitSHA: String, token: String) async throws -> CheckState {
        let url = URL(string: "https://api.github.com/repos/\(repoFullName)/commits/\(commitSHA)/status")
        guard let url else {
            throw GitHubClientError.invalidResponse
        }

        let response: CommitStatusResponse = try await request(url: url, token: token, decodeAs: CommitStatusResponse.self)
        switch response.state {
        case "success":
            return .passing
        case "failure", "error":
            return .failing
        default:
            return .unknown
        }
    }

    static func fetchPullRequestSignals(repoFullName: String, prNumber: Int, token: String) async throws -> PullRequestSignals {
        async let reviewers: ReviewersResponse = request(
            url: URL(string: "https://api.github.com/repos/\(repoFullName)/pulls/\(prNumber)/requested_reviewers")!,
            token: token,
            decodeAs: ReviewersResponse.self
        )

        async let issueComments: [IssueCommentResponse] = request(
            url: URL(string: "https://api.github.com/repos/\(repoFullName)/issues/\(prNumber)/comments?per_page=100")!,
            token: token,
            decodeAs: [IssueCommentResponse].self
        )

        async let reviewComments: [ReviewCommentResponse] = request(
            url: URL(string: "https://api.github.com/repos/\(repoFullName)/pulls/\(prNumber)/comments?per_page=100")!,
            token: token,
            decodeAs: [ReviewCommentResponse].self
        )

        let reviewersResult = try await reviewers
        let issueCommentsResult = try await issueComments
        let reviewCommentsResult = try await reviewComments

        return PullRequestSignals(
            reviewRequestedCount: reviewersResult.users.count + reviewersResult.teams.count,
            issueCommentCount: issueCommentsResult.count,
            reviewCommentCount: reviewCommentsResult.count
        )
    }

    static func fetchLatestWorkflowRun(repoFullName: String, workflowIdentifier: String, branch: String, token: String) async throws -> WorkflowRunSummary? {
        var components = URLComponents(string: "https://api.github.com/repos/\(repoFullName)/actions/workflows/\(workflowIdentifier)/runs")
        components?.queryItems = [
            URLQueryItem(name: "branch", value: branch),
            URLQueryItem(name: "status", value: "completed"),
            URLQueryItem(name: "per_page", value: "10"),
        ]

        guard let url = components?.url else {
            throw GitHubClientError.invalidResponse
        }

        let response: WorkflowRunsResponse = try await request(url: url, token: token, decodeAs: WorkflowRunsResponse.self)
        guard let run = response.workflowRuns.first(where: { $0.conclusion == "success" }) else {
            return nil
        }

        return WorkflowRunSummary(id: run.id, htmlURL: run.htmlURL)
    }

    static func fetchJobs(repoFullName: String, runID: Int, token: String) async throws -> [JobSummary] {
        let url = URL(string: "https://api.github.com/repos/\(repoFullName)/actions/runs/\(runID)/jobs?per_page=100")!
        let response: JobsResponse = try await request(url: url, token: token, decodeAs: JobsResponse.self)
        return response.jobs.map { JobSummary(id: $0.id, name: $0.name) }
    }

    static func fetchJobLogs(repoFullName: String, jobID: Int, token: String) async throws -> String {
        let url = URL(string: "https://api.github.com/repos/\(repoFullName)/actions/jobs/\(jobID)/logs")!
        return try await requestRawText(url: url, token: token)
    }

    static func createPullRequest(
        repoFullName: String,
        title: String,
        body: String,
        head: String,
        base: String,
        token: String
    ) async throws -> CreatedPullRequest {
        let url = URL(string: "https://api.github.com/repos/\(repoFullName)/pulls")!
        let payload = CreatePullRequestRequest(title: title, body: body, head: head, base: base)
        let response: CreatePullRequestResponse = try await requestWithBody(url: url, token: token, body: payload, decodeAs: CreatePullRequestResponse.self)
        return CreatedPullRequest(htmlURL: response.htmlURL)
    }

    private static func owner(from repoFullName: String) throws -> String {
        let parts = repoFullName.split(separator: "/")
        guard parts.count == 2 else {
            throw GitHubClientError.invalidRepositoryName
        }
        return String(parts[0])
    }

    private static func request<T: Decodable>(
        url: URL,
        token: String,
        decodeAs type: T.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("MobileDevOpsBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw GitHubClientError.requestFailed(httpResponse.statusCode)
        }

        return try decoder.decode(type, from: data)
    }

    private static func requestRawText(url: URL, token: String) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("MobileDevOpsBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw GitHubClientError.requestFailed(httpResponse.statusCode)
        }

        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func requestWithBody<Payload: Encodable, T: Decodable>(
        url: URL,
        token: String,
        body: Payload,
        decodeAs type: T.Type
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("MobileDevOpsBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw GitHubClientError.requestFailed(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(type, from: data)
    }
}

private struct PullRequestResponse: Decodable {
    let number: Int
    let htmlURL: String
    let state: String
    let mergedAt: Date?
    let head: Head
    let base: Base

    struct Head: Decodable { let sha: String }
    struct Base: Decodable { let ref: String }

    enum CodingKeys: String, CodingKey {
        case number
        case htmlURL = "html_url"
        case state
        case mergedAt = "merged_at"
        case head
        case base
    }
}

private struct CommitStatusResponse: Decodable { let state: String }

private struct ReviewersResponse: Decodable {
    let users: [ReviewerUser]
    let teams: [ReviewerTeam]
}

private struct ReviewerUser: Decodable { let login: String }
private struct ReviewerTeam: Decodable { let slug: String }
private struct IssueCommentResponse: Decodable { let id: Int }
private struct ReviewCommentResponse: Decodable { let id: Int }

private struct WorkflowRunsResponse: Decodable {
    let workflowRuns: [WorkflowRunResponse]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

private struct WorkflowRunResponse: Decodable {
    let id: Int
    let htmlURL: String
    let conclusion: String?

    enum CodingKeys: String, CodingKey {
        case id
        case htmlURL = "html_url"
        case conclusion
    }
}

private struct JobsResponse: Decodable {
    let jobs: [JobResponse]
}

private struct JobResponse: Decodable {
    let id: Int
    let name: String
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
