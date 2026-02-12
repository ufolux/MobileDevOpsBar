import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SourceRepoConfig.updatedAt, order: .reverse) private var sourceRepos: [SourceRepoConfig]
    @Query(sort: \DeploymentRepoConfig.updatedAt, order: .reverse) private var deploymentRepos: [DeploymentRepoConfig]

    @State private var githubToken = KeychainService.loadGitHubToken()
    @State private var sourceRepoURL = ""
    @State private var sourceRepoPath = ""
    @State private var sourceWorkflow = ""
    @State private var sourceTargetBranch = "main"
    @State private var deployRepoURL = ""
    @State private var deployRepoPath = ""
    @State private var deployEnvBranch = "qa"
    @State private var message = ""
    @AppStorage("autoRefreshEnabled") private var autoRefreshEnabled = false
    @AppStorage("notifyMerged") private var notifyMerged = true
    @AppStorage("notifyChecksFailed") private var notifyChecksFailed = true
    @AppStorage("notifyReviewRequested") private var notifyReviewRequested = true
    @AppStorage("notifyPRComments") private var notifyPRComments = true

    var body: some View {
        Form {
            Section("Authentication") {
                SecureField("GitHub PAT", text: $githubToken)
                Button("Save Token") {
                    do {
                        try KeychainService.saveGitHubToken(githubToken)
                        message = "GitHub token saved to Keychain."
                    } catch {
                        message = "Failed to save token: \(error.localizedDescription)"
                    }
                }
            }

            Section("Source Repos") {
                TextField("Repo URL", text: $sourceRepoURL)
                TextField("Local repo path", text: $sourceRepoPath)
                TextField("Workflow name/file", text: $sourceWorkflow)
                TextField("Default target branch", text: $sourceTargetBranch)
                Button("Add Source Repo") {
                    addSourceRepo()
                }

                ForEach(sourceRepos) { repo in
                    VStack(alignment: .leading) {
                        Text(repo.repoFullName)
                        Text(repo.localPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete(perform: deleteSourceRepos)
            }

            Section("Deployment Repo") {
                TextField("Repo URL", text: $deployRepoURL)
                TextField("Local repo path", text: $deployRepoPath)
                Picker("Default env branch", selection: $deployEnvBranch) {
                    Text("qa").tag("qa")
                    Text("dev").tag("dev")
                }
                .pickerStyle(.segmented)

                Button("Save Deployment Repo") {
                    saveDeploymentRepo()
                }

                ForEach(deploymentRepos) { repo in
                    VStack(alignment: .leading) {
                        Text(repo.repoFullName)
                        Text("Env: \(repo.selectedEnvironmentBranch) | \(DeploymentRepoConfig.configFilePath)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete(perform: deleteDeploymentRepos)
            }

            Section("Refresh") {
                Toggle("Auto refresh every 20 minutes", isOn: $autoRefreshEnabled)
                Text("Manual refresh remains available in menu bar and dashboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Merged", isOn: $notifyMerged)
                Toggle("Checks failed", isOn: $notifyChecksFailed)
                Toggle("Review requested", isOn: $notifyReviewRequested)
                Toggle("PR comments", isOn: $notifyPRComments)
            }

            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 600)
    }

    private func addSourceRepo() {
        guard let repoFullName = RepoURLParser.fullName(from: sourceRepoURL) else {
            message = "Invalid source repo URL."
            return
        }

        let sourceRepo = SourceRepoConfig(
            repoURL: sourceRepoURL,
            repoFullName: repoFullName,
            localPath: sourceRepoPath,
            defaultTargetBranch: sourceTargetBranch,
            workflowIdentifier: sourceWorkflow
        )
        modelContext.insert(sourceRepo)

        sourceRepoURL = ""
        sourceRepoPath = ""
        sourceWorkflow = ""
        sourceTargetBranch = "main"
        message = "Added source repo \(repoFullName)."
    }

    private func saveDeploymentRepo() {
        guard let repoFullName = RepoURLParser.fullName(from: deployRepoURL) else {
            message = "Invalid deployment repo URL."
            return
        }

        if let existing = deploymentRepos.first(where: { $0.repoFullName == repoFullName }) {
            existing.repoURL = deployRepoURL
            existing.localPath = deployRepoPath
            existing.selectedEnvironmentBranch = deployEnvBranch
            existing.updatedAt = .now
            message = "Updated deployment repo \(repoFullName)."
            return
        }

        let deploymentRepo = DeploymentRepoConfig(
            repoURL: deployRepoURL,
            repoFullName: repoFullName,
            localPath: deployRepoPath,
            selectedEnvironmentBranch: deployEnvBranch
        )
        modelContext.insert(deploymentRepo)

        deployRepoURL = ""
        deployRepoPath = ""
        deployEnvBranch = "qa"
        message = "Saved deployment repo \(repoFullName)."
    }

    private func deleteSourceRepos(offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sourceRepos[index])
        }
    }

    private func deleteDeploymentRepos(offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(deploymentRepos[index])
        }
    }
}
