import SwiftUI

struct WorkItemDetailView: View {
    let item: WorkItem
    let onRefresh: () -> Void
    let onCreateDeploymentPR: () -> Void

    var body: some View {
        Form {
            Section("Ticket") {
                LabeledContent("Ticket ID", value: item.ticketID)
                LabeledContent("Source Repo", value: item.sourceRepoFullName)
                LabeledContent("Local Branch", value: item.localBranch)
            }

            Section("PR") {
                LabeledContent("State", value: item.prState.rawValue)
                LabeledContent("Checks", value: item.checkState.rawValue)
                LabeledContent("PR Number", value: item.prNumber.map(String.init) ?? "-")
                LabeledContent("PR URL", value: item.prURL ?? "-")
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
