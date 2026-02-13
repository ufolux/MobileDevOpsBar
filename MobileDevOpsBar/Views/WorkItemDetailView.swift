import SwiftUI

struct WorkItemDetailView: View {
    let item: WorkItem
    let onRefresh: () -> Void
    let onCreateDeploymentPR: () -> Void
    let onCreateSourcePR: () -> Void

    @State private var rallyMarkdownInput = ""
    @State private var rallyMessage = ""
    @State private var selectedWorkflow: WorkflowTab = .mobile
    @State private var sourceBranch = "main"
    @State private var sourceBranchOptions: [String] = []
    @State private var selectedModules: Set<String> = []
    @State private var selectedEnvironments: Set<String> = []
    @State private var moduleVersions: [String: String] = [:]
    @State private var webPRTitle = "Update dockerImageTag"
    @State private var webMessage = ""
    @State private var webLog = ""
    @State private var isLoadingBranches = false
    @State private var isFetchingVersions = false
    @State private var isUpdatingWebPR = false
    @State private var isDeployingWeb = false
    @State private var isRunningWebWorkflow = false

    private enum WorkflowTab: String, CaseIterable, Identifiable {
        case mobile = "Mobile"
        case web = "Web"

        var id: Self { self }
    }

    private var rallyURL: URL? {
        guard let rallyURLString = item.rallyURLString else { return nil }
        return URL(string: rallyURLString)
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
                webWorkflowSection
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
            if sourceBranch.isEmpty {
                sourceBranch = "main"
            }
        }
        .onChange(of: selectedWorkflow) { _, newValue in
            guard newValue == .web else { return }
            if sourceBranchOptions.isEmpty {
                Task { await loadSourceBranches() }
            }
        }
    }

    @ViewBuilder
    private var webWorkflowSection: some View {
            Section {
                HStack {
                    Picker("Source Branch", selection: $sourceBranch) {
                        if sourceBranchOptions.isEmpty {
                            Text(sourceBranch).tag(sourceBranch)
                        } else {
                            ForEach(sourceBranchOptions, id: \.self) { branch in
                                Text(branch).tag(branch)
                            }
                        }
                    }

                    Button(isLoadingBranches ? "Loading..." : "Load Branches") {
                        Task { await loadSourceBranches() }
                    }
                    .disabled(isLoadingBranches || isBusy)
                }
                Text("Repo: \(item.sourceRepoFullName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Source Configuration")
            }

            Section {
                HStack {
                    Button("Select All") {
                        selectedModules = Set(WebWorkflowService.modules)
                    }
                    .disabled(isBusy)

                    Button("Clear All") {
                        selectedModules.removeAll()
                    }
                    .disabled(isBusy)
                }

                ForEach(WebWorkflowService.modules, id: \.self) { module in
                    HStack {
                        Toggle(module, isOn: moduleToggleBinding(for: module))
                            .toggleStyle(.checkbox)
                        TextField("version", text: moduleVersionBinding(for: module))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                    }
                }
            } header: {
                Text("Modules & Versions")
            }

            Section {
                HStack {
                    Button("Select All") {
                        selectedEnvironments = Set(WebWorkflowService.environments)
                    }
                    .disabled(isBusy)

                    Button("Clear All") {
                        selectedEnvironments.removeAll()
                    }
                    .disabled(isBusy)
                }

                ForEach(WebWorkflowService.environments, id: \.self) { environment in
                    Toggle(environment, isOn: environmentToggleBinding(for: environment))
                        .toggleStyle(.checkbox)
                }
            } header: {
                Text("Environments")
            }

            Section {
                TextField("PR Title", text: $webPRTitle)
            } header: {
                Text("PR Details")
            }

            Section {
                HStack {
                    Button(isFetchingVersions ? "Fetching..." : "Fetch Latest Versions") {
                        Task { await fetchLatestVersions() }
                    }
                    .disabled(isFetchingVersions || isBusy)

                    Button(isUpdatingWebPR ? "Updating..." : "Update & Create PR") {
                        Task { await updateAndCreatePR() }
                    }
                    .disabled(isUpdatingWebPR || isBusy)

                    Button(isDeployingWeb ? "Deploying..." : "Deploy to Harness") {
                        Task { await deployToHarness() }
                    }
                    .disabled(isDeployingWeb || isBusy)

                    Button(isRunningWebWorkflow ? "Running..." : "Full Workflow") {
                        Task { await runFullWorkflow() }
                    }
                    .disabled(isRunningWebWorkflow || isBusy)
                }
            } header: {
                Text("Actions")
            }

            Section {
                ScrollView {
                    Text(webLog.isEmpty ? "No logs yet." : webLog)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 150)

                if !webMessage.isEmpty {
                    Text(webMessage)
                        .font(.caption)
                        .foregroundStyle(webMessage.hasPrefix("Success") ? Color.secondary : Color.red)
                }
            } header: {
                Text("Log")
            }
    }

    private var isBusy: Bool {
        isFetchingVersions || isUpdatingWebPR || isDeployingWeb || isRunningWebWorkflow
    }

    private func moduleToggleBinding(for module: String) -> Binding<Bool> {
        Binding(
            get: { selectedModules.contains(module) },
            set: { enabled in
                if enabled {
                    selectedModules.insert(module)
                } else {
                    selectedModules.remove(module)
                }
            }
        )
    }

    private func environmentToggleBinding(for environment: String) -> Binding<Bool> {
        Binding(
            get: { selectedEnvironments.contains(environment) },
            set: { enabled in
                if enabled {
                    selectedEnvironments.insert(environment)
                } else {
                    selectedEnvironments.remove(environment)
                }
            }
        )
    }

    private func moduleVersionBinding(for module: String) -> Binding<String> {
        Binding(
            get: { moduleVersions[module, default: ""] },
            set: { moduleVersions[module] = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
    }

    private var orderedSelectedModules: [String] {
        WebWorkflowService.modules.filter { selectedModules.contains($0) }
    }

    private var orderedSelectedEnvironments: [String] {
        WebWorkflowService.environments.filter { selectedEnvironments.contains($0) }
    }

    private func loadSourceBranches() async {
        let token = KeychainService.loadGitHubToken().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            webMessage = "GitHub PAT is required. Add it in Settings."
            return
        }

        isLoadingBranches = true
        defer { isLoadingBranches = false }

        do {
            let branches = try await GitHubClient.fetchBranches(repoFullName: item.sourceRepoFullName, token: token)
            sourceBranchOptions = branches
            if !branches.contains(sourceBranch), let first = branches.first {
                sourceBranch = first
            }
            appendLog("Loaded \(branches.count) branches for \(item.sourceRepoFullName).")
            webMessage = "Success: source branches loaded."
        } catch {
            webMessage = error.localizedDescription
            appendLog("Failed loading branches: \(error.localizedDescription)")
        }
    }

    private func fetchLatestVersions() async {
        guard validateSelections(requireVersions: false) else { return }

        let token = KeychainService.loadGitHubToken().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            webMessage = "GitHub PAT is required. Add it in Settings."
            return
        }

        isFetchingVersions = true
        defer { isFetchingVersions = false }

        appendLog("Fetching versions from \(item.sourceRepoFullName) on branch \(sourceBranch)...")
        do {
            let versions = try await WebWorkflowService.fetchLatestVersions(
                sourceRepoFullName: item.sourceRepoFullName,
                sourceBranch: sourceBranch,
                modules: orderedSelectedModules,
                token: token
            )
            for (module, version) in versions {
                moduleVersions[module] = version
            }
            webMessage = "Success: versions fetched."
            appendLog("Fetched versions for \(versions.count) module(s).")
        } catch {
            webMessage = error.localizedDescription
            appendLog("Fetch versions failed: \(error.localizedDescription)")
        }
    }

    private func updateAndCreatePR() async {
        guard validateSelections(requireVersions: true) else { return }

        let token = KeychainService.loadGitHubToken().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            webMessage = "GitHub PAT is required. Add it in Settings."
            return
        }

        isUpdatingWebPR = true
        defer { isUpdatingWebPR = false }

        appendLog("Updating values repo and creating PR...")
        do {
            let prResult = try await WebWorkflowService.updateValuesRepoAndMergePR(
                modules: orderedSelectedModules,
                environments: orderedSelectedEnvironments,
                versions: moduleVersions,
                token: token,
                prTitle: webPRTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Update dockerImageTag" : webPRTitle
            )
            webMessage = "Success: PR created and merged."
            appendLog("PR #\(prResult.number) merged: \(prResult.url)")
        } catch {
            webMessage = error.localizedDescription
            appendLog("Update/Create PR failed: \(error.localizedDescription)")
        }
    }

    private func deployToHarness() async {
        guard validateSelections(requireVersions: false) else { return }

        let harnessAPIKey = KeychainService.loadHarnessAPIKey().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !harnessAPIKey.isEmpty else {
            webMessage = "Harness API key is required. Add it in Settings."
            return
        }

        isDeployingWeb = true
        defer { isDeployingWeb = false }

        appendLog("Triggering Harness deployments...")
        do {
            let executionURLs = try await WebWorkflowService.triggerHarnessDeployments(
                modules: orderedSelectedModules,
                environments: orderedSelectedEnvironments,
                harnessAPIKey: harnessAPIKey
            )
            webMessage = "Success: deployment triggered."
            appendLog("Triggered \(executionURLs.count) pipeline(s).")
            for url in executionURLs {
                appendLog(url)
            }
        } catch {
            webMessage = error.localizedDescription
            appendLog("Deploy failed: \(error.localizedDescription)")
        }
    }

    private func runFullWorkflow() async {
        guard validateSelections(requireVersions: false) else { return }

        let token = KeychainService.loadGitHubToken().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            webMessage = "GitHub PAT is required. Add it in Settings."
            return
        }

        let harnessAPIKey = KeychainService.loadHarnessAPIKey().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !harnessAPIKey.isEmpty else {
            webMessage = "Harness API key is required. Add it in Settings."
            return
        }

        isRunningWebWorkflow = true
        defer { isRunningWebWorkflow = false }

        appendLog("Starting full web workflow...")
        do {
            let fetched = try await WebWorkflowService.fetchLatestVersions(
                sourceRepoFullName: item.sourceRepoFullName,
                sourceBranch: sourceBranch,
                modules: orderedSelectedModules,
                token: token
            )
            for (module, version) in fetched {
                moduleVersions[module] = version
            }
            appendLog("Step 1/3 complete: versions fetched.")

            let prResult = try await WebWorkflowService.updateValuesRepoAndMergePR(
                modules: orderedSelectedModules,
                environments: orderedSelectedEnvironments,
                versions: moduleVersions,
                token: token,
                prTitle: webPRTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Update dockerImageTag" : webPRTitle
            )
            appendLog("Step 2/3 complete: PR merged (#\(prResult.number)).")

            let executionURLs = try await WebWorkflowService.triggerHarnessDeployments(
                modules: orderedSelectedModules,
                environments: orderedSelectedEnvironments,
                harnessAPIKey: harnessAPIKey
            )
            appendLog("Step 3/3 complete: \(executionURLs.count) deployment(s) triggered.")
            webMessage = "Success: full workflow completed."
        } catch {
            webMessage = error.localizedDescription
            appendLog("Full workflow failed: \(error.localizedDescription)")
        }
    }

    private func validateSelections(requireVersions: Bool) -> Bool {
        if orderedSelectedModules.isEmpty {
            webMessage = "Select at least one module."
            return false
        }

        if orderedSelectedEnvironments.isEmpty {
            webMessage = "Select at least one environment."
            return false
        }

        if requireVersions {
            for module in orderedSelectedModules {
                let version = moduleVersions[module, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                if version.isEmpty {
                    webMessage = "Missing version for \(module). Fetch versions or enter one manually."
                    return false
                }
            }
        }

        return true
    }

    private func appendLog(_ line: String) {
        if webLog.isEmpty {
            webLog = line
        } else {
            webLog += "\n\(line)"
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
}
