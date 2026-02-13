import SwiftUI
import SwiftData

struct SettingsView: View {
    private enum DeleteTarget: Identifiable {
        case source(UUID)
        case deployment(UUID)

        var id: String {
            switch self {
            case .source(let id): return "source-\(id.uuidString)"
            case .deployment(let id): return "deployment-\(id.uuidString)"
            }
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SourceRepoConfig.updatedAt, order: .reverse) private var sourceRepos: [SourceRepoConfig]
    @Query(sort: \DeploymentRepoConfig.updatedAt, order: .reverse) private var deploymentRepos: [DeploymentRepoConfig]

    @State private var githubToken = KeychainService.loadGitHubToken()
    @State private var harnessAPIKey = KeychainService.loadHarnessAPIKey()
    @State private var sourceRepoURL = ""
    @State private var sourceRepoPath = ""
    @State private var sourceWorkflow = ""
    @State private var sourceTargetBranch = "main"
    @State private var deployRepoURL = ""
    @State private var deployRepoPath = ""
    @State private var deployEnvBranch = "qa"
    @State private var message = ""
    @State private var editingSourceRepoID: UUID?
    @State private var editingDeploymentRepoID: UUID?
    @State private var deleteTarget: DeleteTarget?

    @AppStorage("autoRefreshEnabled") private var autoRefreshEnabled = false
    @AppStorage("notifyMerged") private var notifyMerged = true
    @AppStorage("notifyChecksFailed") private var notifyChecksFailed = true
    @AppStorage("notifyReviewRequested") private var notifyReviewRequested = true
    @AppStorage("notifyPRComments") private var notifyPRComments = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                authSection
                sourceRepoSection
                deploymentSection
                preferencesSection

                if !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .frame(minWidth: 760, minHeight: 620)
        .task {
            restorePersistedRepoSettings()
        }
        .alert("Delete preset?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
            Button("Delete", role: .destructive) {
                confirmDelete()
            }
        } message: {
            Text("This will remove the saved preset from settings.")
        }
    }

    private var authSection: some View {
        GroupBox("Authentication") {
            VStack(alignment: .leading, spacing: 10) {
                SecureField("GitHub PAT", text: $githubToken)
                SecureField("Harness API Key", text: $harnessAPIKey)
                Button("Save Token") {
                    do {
                        try KeychainService.saveGitHubToken(githubToken)
                        try KeychainService.saveHarnessAPIKey(harnessAPIKey)
                        message = "GitHub token and Harness API key saved to Keychain."
                    } catch {
                        message = "Failed to save credentials: \(error.localizedDescription)"
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sourceRepoSection: some View {
        GroupBox("Source Repo Presets") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Repo URL", text: $sourceRepoURL)
                TextField("Local repo path", text: $sourceRepoPath)
                TextField("Workflow name/file", text: $sourceWorkflow)
                TextField("Default target branch", text: $sourceTargetBranch)

                HStack {
                    Button(editingSourceRepoID == nil ? "Add Source Repo" : "Save Source Repo") {
                        saveSourceRepo()
                    }

                    if editingSourceRepoID != nil {
                        Button("Cancel Edit") {
                            clearSourceForm()
                        }
                    }
                }

                Divider()
                Text("Saved Presets")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if sourceRepos.isEmpty {
                    Text("No source presets saved yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sourceRepos) { repo in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(repo.repoFullName)
                                    .font(.headline)
                                Text(repo.localPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Workflow: \(repo.workflowIdentifier) | Base: \(repo.defaultTargetBranch)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") { loadSourceRepoForEditing(repo) }
                            Button("Delete", role: .destructive) {
                                deleteTarget = .source(repo.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var deploymentSection: some View {
        GroupBox("Deployment Repo Presets") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Repo URL", text: $deployRepoURL)
                TextField("Local repo path", text: $deployRepoPath)
                Picker("Default env branch", selection: $deployEnvBranch) {
                    Text("qa").tag("qa")
                    Text("dev").tag("dev")
                }
                .pickerStyle(.segmented)

                HStack {
                    Button(editingDeploymentRepoID == nil ? "Save Deployment Repo" : "Update Deployment Repo") {
                        saveDeploymentRepo()
                    }

                    if editingDeploymentRepoID != nil {
                        Button("Cancel Edit") {
                            clearDeploymentForm()
                        }
                    }
                }

                Divider()
                Text("Saved Presets")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if deploymentRepos.isEmpty {
                    Text("No deployment presets saved yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(deploymentRepos) { repo in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(repo.repoFullName)
                                    .font(.headline)
                                Text(repo.localPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Env: \(repo.selectedEnvironmentBranch) | \(DeploymentRepoConfig.configFilePath)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") { loadDeploymentRepoForEditing(repo) }
                            Button("Delete", role: .destructive) {
                                deleteTarget = .deployment(repo.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var preferencesSection: some View {
        GroupBox("Preferences") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Auto refresh every 20 minutes", isOn: $autoRefreshEnabled)
                Text("Manual refresh remains available in menu bar and dashboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Toggle("Notify on merged PR", isOn: $notifyMerged)
                Toggle("Notify on failed checks", isOn: $notifyChecksFailed)
                Toggle("Notify on review requested", isOn: $notifyReviewRequested)
                Toggle("Notify on PR comments", isOn: $notifyPRComments)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func saveSourceRepo() {
        guard let repoFullName = RepoURLParser.fullName(from: sourceRepoURL) else {
            message = "Invalid source repo URL."
            return
        }

        if let editingID = editingSourceRepoID,
           let editingRepo = sourceRepos.first(where: { $0.id == editingID }) {
            editingRepo.repoURL = sourceRepoURL
            editingRepo.repoFullName = repoFullName
            editingRepo.localPath = sourceRepoPath
            editingRepo.defaultTargetBranch = sourceTargetBranch
            editingRepo.workflowIdentifier = sourceWorkflow
            editingRepo.updatedAt = .now
            persistRepoSettings()
            clearSourceForm()
            message = "Updated source repo \(repoFullName)."
            return
        }

        if let existing = sourceRepos.first(where: { $0.repoFullName == repoFullName }) {
            existing.repoURL = sourceRepoURL
            existing.localPath = sourceRepoPath
            existing.defaultTargetBranch = sourceTargetBranch
            existing.workflowIdentifier = sourceWorkflow
            existing.updatedAt = .now
            persistRepoSettings()
            clearSourceForm()
            message = "Updated source repo \(repoFullName)."
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
        persistRepoSettings()
        clearSourceForm()
        message = "Added source repo \(repoFullName)."
    }

    private func saveDeploymentRepo() {
        guard let repoFullName = RepoURLParser.fullName(from: deployRepoURL) else {
            message = "Invalid deployment repo URL."
            return
        }

        if let editingID = editingDeploymentRepoID,
           let editingRepo = deploymentRepos.first(where: { $0.id == editingID }) {
            editingRepo.repoURL = deployRepoURL
            editingRepo.repoFullName = repoFullName
            editingRepo.localPath = deployRepoPath
            editingRepo.selectedEnvironmentBranch = deployEnvBranch
            editingRepo.updatedAt = .now
            persistRepoSettings()
            clearDeploymentForm()
            message = "Updated deployment repo \(repoFullName)."
            return
        }

        if let existing = deploymentRepos.first(where: { $0.repoFullName == repoFullName }) {
            existing.repoURL = deployRepoURL
            existing.localPath = deployRepoPath
            existing.selectedEnvironmentBranch = deployEnvBranch
            existing.updatedAt = .now
            persistRepoSettings()
            clearDeploymentForm()
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
        persistRepoSettings()
        clearDeploymentForm()
        message = "Saved deployment repo \(repoFullName)."
    }

    private func loadSourceRepoForEditing(_ repo: SourceRepoConfig) {
        editingSourceRepoID = repo.id
        sourceRepoURL = repo.repoURL
        sourceRepoPath = repo.localPath
        sourceWorkflow = repo.workflowIdentifier
        sourceTargetBranch = repo.defaultTargetBranch
        message = "Editing source preset \(repo.repoFullName)."
    }

    private func loadDeploymentRepoForEditing(_ repo: DeploymentRepoConfig) {
        editingDeploymentRepoID = repo.id
        deployRepoURL = repo.repoURL
        deployRepoPath = repo.localPath
        deployEnvBranch = repo.selectedEnvironmentBranch
        message = "Editing deployment preset \(repo.repoFullName)."
    }

    private func clearSourceForm() {
        editingSourceRepoID = nil
        sourceRepoURL = ""
        sourceRepoPath = ""
        sourceWorkflow = ""
        sourceTargetBranch = "main"
    }

    private func clearDeploymentForm() {
        editingDeploymentRepoID = nil
        deployRepoURL = ""
        deployRepoPath = ""
        deployEnvBranch = "qa"
    }

    private func confirmDelete() {
        guard let deleteTarget else { return }

        switch deleteTarget {
        case .source(let id):
            if let repo = sourceRepos.first(where: { $0.id == id }) {
                modelContext.delete(repo)
                if editingSourceRepoID == id {
                    clearSourceForm()
                }
                message = "Deleted source preset."
            }
        case .deployment(let id):
            if let repo = deploymentRepos.first(where: { $0.id == id }) {
                modelContext.delete(repo)
                if editingDeploymentRepoID == id {
                    clearDeploymentForm()
                }
                message = "Deleted deployment preset."
            }
        }

        persistRepoSettings()
        self.deleteTarget = nil
    }

    private func restorePersistedRepoSettings() {
        do {
            try SettingsPersistenceService.restoreRepoSettingsIfNeeded(modelContext: modelContext)
        } catch {
            message = "Failed to restore saved settings: \(error.localizedDescription)"
        }
    }

    private func persistRepoSettings() {
        do {
            try SettingsPersistenceService.saveRepoSettings(modelContext: modelContext)
        } catch {
            message = "Failed to persist repo settings: \(error.localizedDescription)"
        }
    }
}
