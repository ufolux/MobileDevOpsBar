import SwiftUI

struct WorkItemDetailView: View {
    let item: WorkItem
    let onRefresh: () -> Void
    let onCreateDeploymentPR: () -> Void
    let onCreateSourcePR: () -> Void

    @State private var rallyMarkdownInput = ""
    @State private var rallyMessage = ""
    @State private var selectedWorkflow: WorkflowTab = .mobile

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
                Section("Web") {
                    Text("Web workflow placeholder")
                        .foregroundStyle(.secondary)
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
