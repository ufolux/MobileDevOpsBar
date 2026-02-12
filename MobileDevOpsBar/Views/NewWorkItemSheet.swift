import SwiftUI
import SwiftData

struct NewWorkItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SourceRepoConfig.repoFullName) private var sourceRepos: [SourceRepoConfig]

    let existingBranches: [String]
    let onDone: (String) -> Void

    @State private var ticketText = ""
    @State private var selectedRepoID: UUID?
    @State private var createGitBranch = true
    @State private var errorMessage = ""
    @State private var setupRepoURL = ""
    @State private var setupRepoPath = ""
    @State private var setupWorkflow = ""
    @State private var setupTargetBranch = "main"

    private var parsedTickets: [String] {
        TicketParser.parseTickets(from: ticketText)
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

                Text("Tickets")
                    .font(.headline)

                TextEditor(text: $ticketText)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))

                Toggle("Create local git branch now", isOn: $createGitBranch)

                if !parsedTickets.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Parsed tickets")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ForEach(parsedTickets, id: \.self) { ticket in
                            Text("- \(ticket) -> \(BranchNameBuilder.nextBranchName(for: ticket, existingBranches: existingBranches))")
                                .font(.caption)
                        }
                    }
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

        guard !parsedTickets.isEmpty else {
            errorMessage = "No valid tickets found. Use values like US12345 or DE12345."
            return
        }

        var messageParts: [String] = []

        for ticket in parsedTickets {
            let branchName = BranchNameBuilder.nextBranchName(for: ticket, existingBranches: existingBranches + messageParts)
            do {
                if createGitBranch {
                    try GitBranchService.createAndCheckoutBranch(repoPath: selectedRepo.localPath, branchName: branchName)
                }

                let item = WorkItem(
                    ticketID: ticket,
                    sourceRepoFullName: selectedRepo.repoFullName,
                    localBranch: branchName
                )
                modelContext.insert(item)
                messageParts.append(branchName)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        selectedRepo.updatedAt = .now
        onDone("Created \(parsedTickets.count) work item(s).")
        dismiss()
    }
}
