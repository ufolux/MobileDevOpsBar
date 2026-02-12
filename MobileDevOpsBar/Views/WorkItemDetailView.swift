import SwiftUI

struct WorkItemDetailView: View {
    let item: WorkItem
    let onRefresh: () -> Void
    let onCreateDeploymentPR: () -> Void
    let onCreateSourcePR: () -> Void
    @AppStorage("rallyLinkTemplate") private var rallyLinkTemplate = ""

    private var rallyURL: URL? {
        RallyLinkBuilder.url(template: rallyLinkTemplate, ticketID: item.ticketID)
    }

    var body: some View {
        Form {
            Section("Ticket") {
                LabeledContent("Ticket ID", value: item.ticketID)
                LabeledContent("Source Repo", value: item.sourceRepoFullName)
                LabeledContent("Local Branch", value: item.localBranch)
                if let rallyURL {
                    Link("Open Rally Ticket", destination: rallyURL)
                }
            }

            Section("PR") {
                LabeledContent("State", value: item.prState.rawValue)
                LabeledContent("Checks", value: item.checkState.rawValue)
                LabeledContent("PR Number", value: item.prNumber.map(String.init) ?? "-")
                LabeledContent("PR URL", value: item.prURL ?? "-")
                Button("Create Source PR", action: onCreateSourcePR)
            }

            Section("Build Tag") {
                LabeledContent("Latest Tag", value: item.latestTag ?? "-")
                LabeledContent("Last Synced", value: item.lastSyncedAt?.formatted(date: .numeric, time: .shortened) ?? "Never")
            }

            Section("Deployment") {
                LabeledContent("Deployment PR", value: item.deploymentPRURL ?? "-")
                Button("Create Deployment Config PR", action: onCreateDeploymentPR)
                    .disabled(item.latestTag?.isEmpty ?? true)
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
    }
}
