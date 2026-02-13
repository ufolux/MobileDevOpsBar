import Foundation

enum WebWorkflowError: LocalizedError {
    case missingGitHubToken
    case missingHarnessAPIKey
    case invalidResponse
    case githubRequestFailed(Int)
    case harnessRequestFailed(Int)
    case noVersionsFound
    case missingVersion(String)
    case failedToUpdateValuesFile(String)

    var errorDescription: String? {
        switch self {
        case .missingGitHubToken:
            return "GitHub PAT is not configured. Add it in Settings."
        case .missingHarnessAPIKey:
            return "Harness API key is not configured. Add it in Settings."
        case .invalidResponse:
            return "Unexpected API response."
        case .githubRequestFailed(let code):
            return "GitHub API request failed with status code \(code)."
        case .harnessRequestFailed(let code):
            return "Harness API request failed with status code \(code)."
        case .noVersionsFound:
            return "Could not find any module versions in recent workflow logs."
        case .missingVersion(let module):
            return "Missing version for module '\(module)'."
        case .failedToUpdateValuesFile(let path):
            return "Could not update dockerImageTag in \(path)."
        }
    }
}

struct WebPullRequestResult {
    let url: String
    let number: Int
}

enum WebWorkflowService {
    static let modules = [
        "library", "journey", "explore", "health-action", "host", "hra", "mhs", "phr", "coaching",
    ]

    static let environments = ["dev", "qa", "uat", "prod"]

    private static let valuesRepoFullName = "cvs-health-source-code/harness-ng-values-activehealth"
    private static let valuesRepoBaseBranch = "main"
    private static let harnessAccountID = "mTAwmqz1S4SUALu7bLm2jQ"
    private static let harnessOrgID = "cvsdigital"
    private static let harnessProjectID = "activehealth"
    private static let harnessPipelineID = "gkepipeline"
    private static let harnessRepoIdentifier = "harness-ng-pipeline-activehealth"
    private static let harnessBranch = "harness-ng"
    private static let harnessParentEntityConnectorRef = "org.githubemuconnector"
    private static let harnessParentEntityRepoName = "harness-ng-pipeline-activehealth"

    static func fetchLatestVersions(
        sourceRepoFullName: String,
        sourceBranch: String,
        modules: [String],
        token: String
    ) async throws -> [String: String] {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw WebWorkflowError.missingGitHubToken
        }

        let targetModules = Set(modules)
        var foundVersions: [String: String] = [:]
        let runs = try await fetchWorkflowRuns(repoFullName: sourceRepoFullName, branch: sourceBranch, token: trimmedToken)

        for (index, run) in runs.enumerated() {
            if index >= 50 || foundVersions.count == targetModules.count {
                break
            }

            let jobs = try await fetchJobs(repoFullName: sourceRepoFullName, runID: run.id, token: trimmedToken)
            let relevantJobs = jobs.filter { $0.name.contains("Docker Publish") || $0.name.contains("Container Scan") }

            for job in relevantJobs {
                let logs = try await fetchJobLogs(repoFullName: sourceRepoFullName, jobID: job.id, token: trimmedToken)
                let parsed = extractImageVersions(logs: logs, allowedModules: targetModules.subtracting(foundVersions.keys))
                for (module, version) in parsed where foundVersions[module] == nil {
                    foundVersions[module] = version
                }
            }
        }

        guard !foundVersions.isEmpty else {
            throw WebWorkflowError.noVersionsFound
        }

        return foundVersions
    }

    static func updateValuesRepoAndMergePR(
        modules: [String],
        environments: [String],
        versions: [String: String],
        token: String,
        prTitle: String = "Update dockerImageTag"
    ) async throws -> WebPullRequestResult {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw WebWorkflowError.missingGitHubToken
        }

        let branchName = "update-docker-tags-\(timestampString())"
        let baseSHA = try await fetchBranchSHA(repoFullName: valuesRepoFullName, branch: valuesRepoBaseBranch, token: trimmedToken)
        try await createBranch(repoFullName: valuesRepoFullName, branch: branchName, baseSHA: baseSHA, token: trimmedToken)

        for module in modules {
            guard let version = versions[module], !version.isEmpty else {
                throw WebWorkflowError.missingVersion(module)
            }

            for environment in environments {
                let cleanedModule = module.replacingOccurrences(of: "-", with: "")
                let filePath = "mah-ui-web-\(cleanedModule)-svc/mah-ui-web-\(environment)/values/v1.yaml"
                try await updateDockerTag(
                    repoFullName: valuesRepoFullName,
                    filePath: filePath,
                    branch: branchName,
                    version: version,
                    token: trimmedToken
                )
            }
        }

        let body = makePRBody(modules: modules, versions: versions)
        let created = try await createPullRequest(
            repoFullName: valuesRepoFullName,
            title: prTitle,
            body: body,
            head: branchName,
            base: valuesRepoBaseBranch,
            token: trimmedToken
        )

        try await mergePullRequest(
            repoFullName: valuesRepoFullName,
            number: created.number,
            method: "squash",
            token: trimmedToken
        )

        return WebPullRequestResult(url: created.url, number: created.number)
    }

    static func triggerHarnessDeployments(
        modules: [String],
        environments: [String],
        harnessAPIKey: String
    ) async throws -> [String] {
        let trimmedAPIKey = harnessAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else {
            throw WebWorkflowError.missingHarnessAPIKey
        }

        var executionURLs: [String] = []

        for module in modules {
            for environment in environments {
                let runtimeYAML = runtimeInputsYAML(module: module, environment: environment)
                if let url = try await triggerHarnessExecution(runtimeYAML: runtimeYAML, harnessAPIKey: trimmedAPIKey) {
                    executionURLs.append(url)
                }
            }
        }

        return executionURLs
    }

    private static func fetchWorkflowRuns(repoFullName: String, branch: String, token: String) async throws -> [WorkflowRun] {
        var components = URLComponents(string: "https://api.github.com/repos/\(repoFullName)/actions/runs")
        components?.queryItems = [
            URLQueryItem(name: "branch", value: branch),
            URLQueryItem(name: "per_page", value: "100"),
        ]
        guard let url = components?.url else {
            throw WebWorkflowError.invalidResponse
        }

        let response: WorkflowRunsResponse = try await requestGitHub(url: url, token: token, decodeAs: WorkflowRunsResponse.self)
        return response.workflowRuns.map { WorkflowRun(id: $0.id, htmlURL: $0.htmlURL) }
    }

    private static func fetchJobs(repoFullName: String, runID: Int, token: String) async throws -> [WorkflowJob] {
        let url = URL(string: "https://api.github.com/repos/\(repoFullName)/actions/runs/\(runID)/jobs?per_page=100")!
        let response: JobsResponse = try await requestGitHub(url: url, token: token, decodeAs: JobsResponse.self)
        return response.jobs.map { WorkflowJob(id: $0.id, name: $0.name) }
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
            throw WebWorkflowError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebWorkflowError.githubRequestFailed(httpResponse.statusCode)
        }

        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func extractImageVersions(logs: String, allowedModules: Set<String>) -> [String: String] {
        let pattern = #"CONTAINER_IMAGE_INFO:\s+cvsh\.jfrog\.io/[^/]+/[^/]+/[^/]+/[^/]+/([^:]+):([^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [:]
        }

        let range = NSRange(logs.startIndex..., in: logs)
        let matches = regex.matches(in: logs, range: range)
        var result: [String: String] = [:]

        for match in matches where match.numberOfRanges == 3 {
            guard
                let moduleRange = Range(match.range(at: 1), in: logs),
                let versionRange = Range(match.range(at: 2), in: logs)
            else {
                continue
            }

            let module = String(logs[moduleRange])
            let version = String(logs[versionRange])
            if allowedModules.contains(module), result[module] == nil {
                result[module] = version
            }
        }

        return result
    }

    private static func fetchBranchSHA(repoFullName: String, branch: String, token: String) async throws -> String {
        let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        let url = URL(string: "https://api.github.com/repos/\(repoFullName)/git/ref/heads/\(encodedBranch)")!
        let response: GitRefResponse = try await requestGitHub(url: url, token: token, decodeAs: GitRefResponse.self)
        return response.object.sha
    }

    private static func createBranch(repoFullName: String, branch: String, baseSHA: String, token: String) async throws {
        let url = URL(string: "https://api.github.com/repos/\(repoFullName)/git/refs")!
        let payload = CreateGitRefRequest(ref: "refs/heads/\(branch)", sha: baseSHA)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("MobileDevOpsBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebWorkflowError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebWorkflowError.githubRequestFailed(httpResponse.statusCode)
        }
    }

    private static func updateDockerTag(repoFullName: String, filePath: String, branch: String, version: String, token: String) async throws {
        let file = try await fetchRepositoryFile(repoFullName: repoFullName, filePath: filePath, branch: branch, token: token)
        let updatedContent = try replaceDockerTag(in: file.content, version: version, filePath: filePath)

        let payload = UpdateFileRequest(
            message: "Update dockerImageTag to \(version) for \(filePath)",
            content: Data(updatedContent.utf8).base64EncodedString(),
            sha: file.sha,
            branch: branch
        )

        let encodedPath = filePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filePath
        let url = URL(string: "https://api.github.com/repos/\(repoFullName)/contents/\(encodedPath)")!
        _ = try await requestGitHubWithBody(url: url, method: "PUT", token: token, body: payload)
    }

    private static func fetchRepositoryFile(repoFullName: String, filePath: String, branch: String, token: String) async throws -> RepositoryFile {
        let encodedPath = filePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filePath
        var components = URLComponents(string: "https://api.github.com/repos/\(repoFullName)/contents/\(encodedPath)")
        components?.queryItems = [URLQueryItem(name: "ref", value: branch)]
        guard let url = components?.url else {
            throw WebWorkflowError.invalidResponse
        }

        let response: RepositoryContentResponse = try await requestGitHub(url: url, token: token, decodeAs: RepositoryContentResponse.self)
        let sanitized = response.content.replacingOccurrences(of: "\n", with: "")
        guard
            let data = Data(base64Encoded: sanitized),
            let content = String(data: data, encoding: .utf8)
        else {
            throw WebWorkflowError.invalidResponse
        }

        return RepositoryFile(content: content, sha: response.sha)
    }

    private static func replaceDockerTag(in content: String, version: String, filePath: String) throws -> String {
        let pattern = #"(dockerImageTag:\s+)[^\s]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw WebWorkflowError.failedToUpdateValuesFile(filePath)
        }

        let range = NSRange(content.startIndex..., in: content)
        let updated = regex.stringByReplacingMatches(in: content, range: range, withTemplate: "$1\(version)")
        if updated == content {
            throw WebWorkflowError.failedToUpdateValuesFile(filePath)
        }
        return updated
    }

    private static func makePRBody(modules: [String], versions: [String: String]) -> String {
        var lines = ["Automated update of dockerImageTag", "", "Updated modules:"]
        for module in modules {
            if let version = versions[module] {
                lines.append("- \(module): \(version)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func mergePullRequest(repoFullName: String, number: Int, method: String, token: String) async throws {
        let url = URL(string: "https://api.github.com/repos/\(repoFullName)/pulls/\(number)/merge")!
        let payload = MergePullRequestRequest(mergeMethod: method)
        _ = try await requestGitHubWithBody(url: url, method: "PUT", token: token, body: payload)
    }

    private static func createPullRequest(
        repoFullName: String,
        title: String,
        body: String,
        head: String,
        base: String,
        token: String
    ) async throws -> WebPullRequestResult {
        let url = URL(string: "https://api.github.com/repos/\(repoFullName)/pulls")!
        let payload = CreatePullRequestRequest(title: title, body: body, head: head, base: base)
        let data = try await requestGitHubWithBody(url: url, method: "POST", token: token, body: payload)
        let decoded = try JSONDecoder().decode(CreatePullRequestResponse.self, from: data)
        return WebPullRequestResult(url: decoded.htmlURL, number: decoded.number)
    }

    private static func triggerHarnessExecution(runtimeYAML: String, harnessAPIKey: String) async throws -> String? {
        let endpoint = URL(string: "https://app.harness.io/gateway/pipeline/api/pipeline/execute/\(harnessPipelineID)")!
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "routingId", value: harnessAccountID),
            URLQueryItem(name: "accountIdentifier", value: harnessAccountID),
            URLQueryItem(name: "projectIdentifier", value: harnessProjectID),
            URLQueryItem(name: "orgIdentifier", value: harnessOrgID),
            URLQueryItem(name: "moduleType", value: ""),
            URLQueryItem(name: "repoIdentifier", value: harnessRepoIdentifier),
            URLQueryItem(name: "branch", value: harnessBranch),
            URLQueryItem(name: "notifyOnlyUser", value: "false"),
            URLQueryItem(name: "parentEntityConnectorRef", value: harnessParentEntityConnectorRef),
            URLQueryItem(name: "parentEntityRepoName", value: harnessParentEntityRepoName),
            URLQueryItem(name: "asyncPlanCreation", value: "false"),
        ]

        guard let url = components?.url else {
            throw WebWorkflowError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(harnessAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/yaml", forHTTPHeaderField: "Content-Type")
        request.setValue(harnessAccountID, forHTTPHeaderField: "Harness-Account")
        request.httpBody = Data(runtimeYAML.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebWorkflowError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebWorkflowError.harnessRequestFailed(httpResponse.statusCode)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataObject = json["data"] as? [String: Any],
            let executionURL = dataObject["executionUrl"] as? String,
            !executionURL.isEmpty
        else {
            return nil
        }

        return executionURL
    }

    private static func runtimeInputsYAML(module: String, environment: String) -> String {
        let cleanedModule = module.replacingOccurrences(of: "-", with: "")
        return """
        pipeline:
          identifier: gkepipeline
          template:
            templateInputs:
              stages:
                - stage:
                    identifier: initialize
                    type: Deployment
                    spec:
                      service:
                        serviceRef: mah_ui_web_\(cleanedModule)_svc
                      environment:
                        environmentRef: mah_ui_web_\(environment)
                        infrastructureDefinitions:
                          - identifier: mah_ui_web_\(environment)
                    variables:
                      - name: ISTIO_CANARY_WEIGHTAGE
                        type: Number
                        default: 0
                        value: 0
                      - name: HELM_VALUES_FILE_NAME
                        type: String
                        value: v1
                      - name: COOKIE_BASED_TRAFFIC_ROUTING
                        type: String
                        default: "false"
                        value: "false"
                - stage:
                    identifier: rfc_inputs
                    type: Custom
                    variables:
                      - name: CHANGE_DESCRIPTION
                        type: String
                        value: <+input>.executionInput()
                      - name: RFC_SHORT_DESC
                        type: String
                        value: <+input>.executionInput()
                      - name: CHANGE_IMPACTED_WEBSITE
                        type: String
                        value: <+input>.executionInput().allowedValues(CVS.COM,CAREMARK.COM,AETNA.COM,SPECIALTY,CARE.CVS.COM,myactivehealth.com)
                      - name: CHANGE_DOMAIN
                        type: String
                        value: <+input>.executionInput().allowedValues(Enterprise,Health Care Business(HCB),Lower Level Environment(LLE),Pharmacy Services(PS),Pharmacy & Cosumer Wellness(PCW),Health Care Delivery(HCD))
                      - name: RFC_IQOQ
                        type: String
                        default: <+pipeline.stages.initialize.spec.execution.steps.init_validate.output.outputVariables.RFC_IQOQ>
                        value: <+input>.executionInput().default(<+pipeline.stages.initialize.spec.execution.steps.init_validate.output.outputVariables.RFC_IQOQ>)
                      - name: RFC_BACKOUT_PLAN
                        type: String
                        default: <+pipeline.stages.initialize.spec.execution.steps.init_validate.output.outputVariables.RFC_BO_PLAN>
                        value: <+input>.executionInput().default(<+pipeline.stages.initialize.spec.execution.steps.init_validate.output.outputVariables.RFC_BO_PLAN>)
                      - name: RFC_NUMBER
                        type: String
                        value: <+input>.executionInput()
              delegateSelectors:
                - ahm-pop-\(environment)-gke-ng-delegate
        """
    }

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func requestGitHub<T: Decodable>(url: URL, token: String, decodeAs: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("MobileDevOpsBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebWorkflowError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebWorkflowError.githubRequestFailed(httpResponse.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    private static func requestGitHubWithBody<Payload: Encodable>(
        url: URL,
        method: String,
        token: String,
        body: Payload
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("MobileDevOpsBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebWorkflowError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebWorkflowError.githubRequestFailed(httpResponse.statusCode)
        }

        return data
    }
}

private struct RepositoryFile {
    let content: String
    let sha: String
}

private struct WorkflowRun {
    let id: Int
    let htmlURL: String
}

private struct WorkflowJob {
    let id: Int
    let name: String
}

private struct WorkflowRunsResponse: Decodable {
    let workflowRuns: [WorkflowRunResponse]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

private struct WorkflowRunResponse: Decodable {
    let id: Int
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case id
        case htmlURL = "html_url"
    }
}

private struct JobsResponse: Decodable {
    let jobs: [JobResponse]
}

private struct JobResponse: Decodable {
    let id: Int
    let name: String
}

private struct GitRefResponse: Decodable {
    let object: GitRefObject
}

private struct GitRefObject: Decodable {
    let sha: String
}

private struct CreateGitRefRequest: Encodable {
    let ref: String
    let sha: String
}

private struct RepositoryContentResponse: Decodable {
    let content: String
    let sha: String
}

private struct UpdateFileRequest: Encodable {
    let message: String
    let content: String
    let sha: String
    let branch: String
}

private struct CreatePullRequestRequest: Encodable {
    let title: String
    let body: String
    let head: String
    let base: String
}

private struct CreatePullRequestResponse: Decodable {
    let number: Int
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case number
        case htmlURL = "html_url"
    }
}

private struct MergePullRequestRequest: Encodable {
    let mergeMethod: String

    enum CodingKeys: String, CodingKey {
        case mergeMethod = "merge_method"
    }
}
