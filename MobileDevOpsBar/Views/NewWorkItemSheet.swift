import SwiftUI
import SwiftData

struct NewWorkItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SourceRepoConfig.repoFullName) private var sourceRepos: [SourceRepoConfig]

    let existingBranches: [String]
    let onDone: (String) -> Void

    @State private var rallyMarkdownText = ""
    @State private var selectedRepoID: UUID?
    @State private var createGitBranch = true
    @State private var errorMessage = ""
    @State private var setupRepoURL = ""
    @State private var setupRepoPath = ""
    @State private var setupWorkflow = ""
    @State private var setupTargetBranch = "main"

    private var parsedRallyEntries: [RallyEntry] {
        RallyMarkdownParser.parseEntries(from: rallyMarkdownText).entries
    }

    private var invalidRallyLines: [String] {
        RallyMarkdownParser.parseEntries(from: rallyMarkdownText).invalidLines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("New Work Item")
                    .font(.title2)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
            }

            if sourceRepos.isEmpty {
                Text("Initialize Source Repo")
                    .font(.headline)

                Text("No source repo is configured yet. Add one now to start creating work items.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("Repo URL", text: $setupRepoURL)
                TextField("Local repo path", text: $setupRepoPath)
                TextField("Workflow name/file", text: $setupWorkflow)
                TextField("Default target branch", text: $setupTargetBranch)

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                HStack {
                    Spacer()
                    Button("Initialize Repo") {
                        initializeSourceRepo()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Picker("Source Repo", selection: $selectedRepoID) {
                    ForEach(sourceRepos) { repo in
                        Text(repo.repoFullName).tag(Optional(repo.id))
                    }
                }

                Text("Rally Links")
                    .font(.headline)

                TextEditor(text: $rallyMarkdownText)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))

                Text("Use one line per item in markdown format: [DF1234](https://rally.example.com/...) ")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Create local git branch now", isOn: $createGitBranch)

                if !parsedRallyEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Parsed work items")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ForEach(parsedRallyEntries, id: \.markdown) { entry in
                            Text("- \(entry.ticketNumber) -> \(BranchNameBuilder.nextBranchName(for: entry.ticketNumber, existingBranches: existingBranches))")
                                .font(.caption)
                        }
                    }
                }

                if !invalidRallyLines.isEmpty {
                    Text("Invalid lines: \(invalidRallyLines.count). Expected [Ticket](url).")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                HStack {
                    Spacer()
                    Button("Cancel") {
                        dismiss()
                    }
                    Button("Create") {
                        createWorkItems()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 580)
        .onAppear {
            try? SettingsPersistenceService.restoreRepoSettingsIfNeeded(modelContext: modelContext)
            if selectedRepoID == nil {
                selectedRepoID = sourceRepos.first?.id
            }
        }
    }

    private func initializeSourceRepo() {
        guard let repoFullName = RepoURLParser.fullName(from: setupRepoURL) else {
            errorMessage = "Invalid repo URL."
            return
        }

        let localPath = setupRepoPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let workflow = setupWorkflow.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetBranch = setupTargetBranch.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !localPath.isEmpty, !workflow.isEmpty else {
            errorMessage = "Local path and workflow are required."
            return
        }

        let sourceRepo = SourceRepoConfig(
            repoURL: setupRepoURL,
            repoFullName: repoFullName,
            localPath: localPath,
            defaultTargetBranch: targetBranch.isEmpty ? "main" : targetBranch,
            workflowIdentifier: workflow
        )
        modelContext.insert(sourceRepo)
        try? SettingsPersistenceService.saveRepoSettings(modelContext: modelContext)

        selectedRepoID = sourceRepo.id
        errorMessage = ""
    }

    private func createWorkItems() {
        guard let selectedRepo = sourceRepos.first(where: { $0.id == selectedRepoID }) else {
            errorMessage = "Please select a source repo."
            return
        }

        let parsed = RallyMarkdownParser.parseEntries(from: rallyMarkdownText)
        guard !parsed.entries.isEmpty else {
            errorMessage = "No valid Rally lines found. Use [Ticket](url)."
            return
        }

        guard parsed.invalidLines.isEmpty else {
            errorMessage = "Some lines are invalid. Fix markdown format and try again."
            return
        }

        var messageParts: [String] = []

        for entry in parsed.entries {
            let branchName = BranchNameBuilder.nextBranchName(for: entry.ticketNumber, existingBranches: existingBranches + messageParts)
            do {
                if createGitBranch {
                    try GitBranchService.createAndCheckoutBranch(repoPath: selectedRepo.localPath, branchName: branchName)
                }

                let item = WorkItem(
                    ticketID: entry.ticketNumber,
                    sourceRepoFullName: selectedRepo.repoFullName,
                    localBranch: branchName,
                    rallyMarkdown: entry.markdown,
                    rallyTicketNumber: entry.ticketNumber,
                    rallyURLString: entry.url.absoluteString
                )
                modelContext.insert(item)
                messageParts.append(branchName)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        selectedRepo.updatedAt = .now
        onDone("Created \(parsed.entries.count) work item(s).")
        dismiss()
    }
}
