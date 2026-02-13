import SwiftUI
import SwiftData

struct WorkItemDetailView: View {
    @Query(sort: \DeploymentRepoConfig.updatedAt, order: .reverse) private var deploymentRepos: [DeploymentRepoConfig]

    let item: WorkItem
    let onRefresh: () -> Void
    let onCreateDeploymentPR: () -> Void
    let onCreateSourcePR: () -> Void

    @State private var rallyMarkdownInput = ""
    @State private var rallyMessage = ""
    @State private var selectedWorkflow: WorkflowTab = .mobile
    @State private var webSourceBranch = ""
    @State private var webStatusMessage = ""
    @State private var webVersionMap: [String: String] = [:]
    @State private var isFetchingWebVersions = false
    @State private var isCreatingWebPR = false
    @State private var isRunningWebWorkflow = false

    @AppStorage("webDeploymentRepoFullName") private var webDeploymentRepoFullName = ""
    @AppStorage("webDeploymentBaseBranch") private var webDeploymentBaseBranch = "harness-ng"
    @AppStorage("webWorkflowModules") private var webWorkflowModules = ""
    @AppStorage("webWorkflowEnvironments") private var webWorkflowEnvironments = ""
    @AppStorage("webWorkflowPRTitle") private var webWorkflowPRTitle = "Update dockerImageTag"

    private enum WorkflowTab: String, CaseIterable, Identifiable {
        case mobile = "Mobile"
        case web = "Web"

        var id: Self { self }
    }

    private var rallyURL: URL? {
        guard let rallyURLString = item.rallyURLString else { return nil }
        return URL(string: rallyURLString)
    }

    private var sourcePRURL: URL? {
        guard let prURL = item.prURL else { return nil }
        return URL(string: prURL)
    }

    private var deploymentPRURL: URL? {
        guard let deploymentPRURL = item.deploymentPRURL else { return nil }
        return URL(string: deploymentPRURL)
    }

    var body: some View {
        Form {
            Section("Ticket") {
                LabeledContent("Ticket ID", value: item.ticketID)
                LabeledContent("Source Repo", value: item.sourceRepoFullName)
                LabeledContent("Local Branch", value: item.localBranch)
            }

            Section("Rally Link") {
                TextField("[DF1234](https://...)", text: $rallyMarkdownInput)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save Rally Link") {
                        saveRallyLink()
                    }

                    if let rallyURL {
                        Link("Open Rally Ticket", destination: rallyURL)
                    }
                }

                if !rallyMessage.isEmpty {
                    Text(rallyMessage)
                        .font(.caption)
                        .foregroundColor(rallyMessage.hasPrefix("Saved") ? .secondary : .red)
                }
            }

            Section("PR") {
                LabeledContent("State", value: item.prState.rawValue)
                LabeledContent("Checks", value: item.checkState.rawValue)
                LabeledContent("PR Number", value: item.prNumber.map(String.init) ?? "-")
                LabeledContent("PR URL", value: item.prURL ?? "-")
                Button("Create Source PR", action: onCreateSourcePR)
            }

            Section("Workflow") {
                Picker("Platform", selection: $selectedWorkflow) {
                    ForEach(WorkflowTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
            }

            if selectedWorkflow == .mobile {
                Section("Build Tag") {
                    LabeledContent("Latest Tag", value: item.latestTag ?? "-")
                    LabeledContent("Last Synced", value: item.lastSyncedAt?.formatted(date: .numeric, time: .shortened) ?? "Never")
                }

                Section("Deployment") {
                    LabeledContent("Deployment PR", value: item.deploymentPRURL ?? "-")
                    Button("Create Deployment Config PR", action: onCreateDeploymentPR)
                        .disabled(item.latestTag?.isEmpty ?? true)
                }
            } else {
                Section("Web Workflow") {
                    Text("Use workflow logs to fetch module tags, then update deployment values and open a PR.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Source branch", text: $webSourceBranch)
                    TextField("Deployment repo (owner/repo)", text: $webDeploymentRepoFullName)
                    TextField("Deployment base branch", text: $webDeploymentBaseBranch)

                    HStack {
                        TextField("Modules (comma/newline separated)", text: $webWorkflowModules, axis: .vertical)
                            .lineLimit(2...4)
                        TextField("Environments (comma/newline separated)", text: $webWorkflowEnvironments, axis: .vertical)
                            .lineLimit(2...4)
                    }

                    TextField("PR title", text: $webWorkflowPRTitle)

                    if !webVersionMap.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Resolved versions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(webVersionMap.keys.sorted(), id: \.self) { module in
                                HStack {
                                    Text(module)
                                        .font(.callout)
                                        .frame(width: 180, alignment: .leading)
                                    TextField("version", text: bindingForVersion(module: module))
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                    }

                    HStack {
                        Button(isFetchingWebVersions ? "Fetching..." : "Fetch Latest Versions") {
                            Task { await fetchWebVersions() }
                        }
                        .disabled(isFetchingWebVersions || isCreatingWebPR || isRunningWebWorkflow)

                        Button(isCreatingWebPR ? "Creating PR..." : "Create Web Deployment PR") {
                            Task { await createWebDeploymentPR() }
                        }
                        .disabled(isFetchingWebVersions || isCreatingWebPR || isRunningWebWorkflow)

                        Button(isRunningWebWorkflow ? "Running..." : "Run Full Workflow") {
                            Task { await runWebWorkflow() }
                        }
                        .disabled(isFetchingWebVersions || isCreatingWebPR || isRunningWebWorkflow)

                        if let sourcePRURL {
                            Link("Open Source PR", destination: sourcePRURL)
                        }

                        if let deploymentPRURL {
                            Link("Open Deployment PR", destination: deploymentPRURL)
                        }
                    }

                    if !webStatusMessage.isEmpty {
                        Text(webStatusMessage)
                            .font(.caption)
                            .foregroundColor(webStatusMessage.hasPrefix("Done") ? .secondary : .red)
                    }
                }
            }

            if let lastError = item.lastErrorMessage, !lastError.isEmpty {
                Section("Last Error") {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Button("Refresh Item", action: onRefresh)
        }
        .formStyle(.grouped)
        .onAppear {
            rallyMarkdownInput = item.rallyMarkdown ?? ""
            webSourceBranch = item.localBranch
            if webDeploymentRepoFullName.isEmpty, let firstRepo = deploymentRepos.first {
                webDeploymentRepoFullName = firstRepo.repoFullName
            }
            if webWorkflowEnvironments.isEmpty {
                webWorkflowEnvironments = "qa"
            }
        }
    }

    private func saveRallyLink() {
        let trimmed = rallyMarkdownInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            item.rallyMarkdown = nil
            item.rallyTicketNumber = nil
            item.rallyURLString = nil
            rallyMessage = "Saved: cleared Rally link."
            item.updatedAt = .now
            return
        }

        guard let entry = RallyMarkdownParser.parseEntry(from: trimmed) else {
            rallyMessage = "Invalid markdown. Use [Ticket](url)."
            return
        }

        item.rallyMarkdown = entry.markdown
        item.rallyTicketNumber = entry.ticketNumber
        item.rallyURLString = entry.url.absoluteString
        item.ticketID = entry.ticketNumber
        rallyMessage = "Saved Rally link."
        item.updatedAt = .now
    }

    private func bindingForVersion(module: String) -> Binding<String> {
        Binding(
            get: { webVersionMap[module] ?? "" },
            set: { webVersionMap[module] = $0 }
        )
    }

    private func parseList(_ raw: String) -> [String] {
        raw
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    @MainActor
    private func fetchWebVersions() async {
        let token = KeychainService.loadGitHubToken().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            webStatusMessage = "GitHub PAT is missing. Save it in Settings first."
            return
        }

        let modules = parseList(webWorkflowModules)
        guard !modules.isEmpty else {
            webStatusMessage = "Enter at least one module before fetching versions."
            return
        }

        let branch = webSourceBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else {
            webStatusMessage = "Source branch is required."
            return
        }

        isFetchingWebVersions = true
        defer { isFetchingWebVersions = false }

        do {
            let versions = try await WebWorkflowService.findLatestVersions(
                repoFullName: item.sourceRepoFullName,
                branch: branch,
                modules: modules,
                token: token
            )

            if versions.isEmpty {
                webStatusMessage = "No matching versions were found in recent workflow runs."
                return
            }

            for module in modules {
                if let version = versions[module] {
                    webVersionMap[module] = version
                }
            }
            webStatusMessage = "Done: fetched \(versions.count) module version(s)."
        } catch {
            webStatusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func createWebDeploymentPR() async {
        let token = KeychainService.loadGitHubToken().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            webStatusMessage = "GitHub PAT is missing. Save it in Settings first."
            return
        }

        let deploymentRepo = webDeploymentRepoFullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deploymentRepo.isEmpty else {
            webStatusMessage = "Deployment repo is required (owner/repo)."
            return
        }

        let baseBranch = webDeploymentBaseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseBranch.isEmpty else {
            webStatusMessage = "Deployment base branch is required."
            return
        }

        let modules = parseList(webWorkflowModules)
        let environments = parseList(webWorkflowEnvironments)
        let sourceBranch = webSourceBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = webWorkflowPRTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sourceBranch.isEmpty else {
            webStatusMessage = "Source branch is required."
            return
        }

        guard !title.isEmpty else {
            webStatusMessage = "PR title is required."
            return
        }

        isCreatingWebPR = true
        defer { isCreatingWebPR = false }

        do {
            let result = try await WebWorkflowService.createWebDeploymentPullRequest(
                deploymentRepoFullName: deploymentRepo,
                baseBranch: baseBranch,
                sourceRepoFullName: item.sourceRepoFullName,
                sourceBranch: sourceBranch,
                modules: modules,
                environments: environments,
                versions: webVersionMap,
                prTitle: title,
                token: token,
                ticketID: item.ticketID,
                sourcePRURL: item.prURL
            )
            item.deploymentPRURL = result.pullRequestURL
            item.updatedAt = .now
            webStatusMessage = "Done: created deployment PR and updated \(result.updatedFileCount) file(s)."
        } catch {
            webStatusMessage = error.localizedDescription
            item.lastErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func runWebWorkflow() async {
        let token = KeychainService.loadGitHubToken().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            webStatusMessage = "GitHub PAT is missing. Save it in Settings first."
            return
        }

        let deploymentRepo = webDeploymentRepoFullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deploymentRepo.isEmpty else {
            webStatusMessage = "Deployment repo is required (owner/repo)."
            return
        }

        let baseBranch = webDeploymentBaseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseBranch.isEmpty else {
            webStatusMessage = "Deployment base branch is required."
            return
        }

        let modules = parseList(webWorkflowModules)
        guard !modules.isEmpty else {
            webStatusMessage = "Enter at least one module before running workflow."
            return
        }

        let environments = parseList(webWorkflowEnvironments)
        guard !environments.isEmpty else {
            webStatusMessage = "Enter at least one environment before running workflow."
            return
        }

        let sourceBranch = webSourceBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceBranch.isEmpty else {
            webStatusMessage = "Source branch is required."
            return
        }

        let title = webWorkflowPRTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            webStatusMessage = "PR title is required."
            return
        }

        isRunningWebWorkflow = true
        defer { isRunningWebWorkflow = false }

        do {
            webStatusMessage = "Step 1/2: fetching module versions..."
            let fetchedVersions = try await WebWorkflowService.findLatestVersions(
                repoFullName: item.sourceRepoFullName,
                branch: sourceBranch,
                modules: modules,
                token: token
            )

            if fetchedVersions.isEmpty {
                webStatusMessage = "No matching versions were found in recent workflow runs."
                return
            }

            for module in modules {
                if let version = fetchedVersions[module] {
                    webVersionMap[module] = version
                }
            }

            webStatusMessage = "Step 2/2: creating deployment PR..."
            let result = try await WebWorkflowService.createWebDeploymentPullRequest(
                deploymentRepoFullName: deploymentRepo,
                baseBranch: baseBranch,
                sourceRepoFullName: item.sourceRepoFullName,
                sourceBranch: sourceBranch,
                modules: modules,
                environments: environments,
                versions: webVersionMap,
                prTitle: title,
                token: token,
                ticketID: item.ticketID,
                sourcePRURL: item.prURL
            )

            item.deploymentPRURL = result.pullRequestURL
            item.updatedAt = .now
            webStatusMessage = "Done: full workflow completed, updated \(result.updatedFileCount) file(s)."
        } catch {
            webStatusMessage = error.localizedDescription
            item.lastErrorMessage = error.localizedDescription
        }
    }
}
