import SwiftUI
import SwiftData
import Combine

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkItem.updatedAt, order: .reverse) private var workItems: [WorkItem]
    @Query(sort: \SourceRepoConfig.updatedAt, order: .reverse) private var sourceRepos: [SourceRepoConfig]
    @Query(sort: \DeploymentRepoConfig.updatedAt, order: .reverse) private var deploymentRepos: [DeploymentRepoConfig]

    @State private var showingNewWorkItem = false
    @State private var selectedWorkItemID: UUID?
    @State private var statusMessage = "Ready"

    @AppStorage("autoRefreshEnabled") private var autoRefreshEnabled = false
    @AppStorage("notifyMerged") private var notifyMerged = true
    @AppStorage("notifyChecksFailed") private var notifyChecksFailed = true
    @AppStorage("notifyReviewRequested") private var notifyReviewRequested = true
    @AppStorage("notifyPRComments") private var notifyPRComments = true

    private let autoRefreshTimer = Timer.publish(every: 1200, on: .main, in: .common).autoconnect()

    private var selectedWorkItem: WorkItem? {
        guard let selectedWorkItemID else { return nil }
        return workItems.first(where: { $0.id == selectedWorkItemID })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedWorkItemID) {
                if workItems.isEmpty {
                    ContentUnavailableView(
                        "No work items yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Create a work item to start ticket-to-PR tracking.")
                    )
                }

                ForEach(workItems) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.ticketID)
                            .font(.headline)
                        Text(item.localBranch)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text(item.prState.rawValue)
                            if let tag = item.latestTag {
                                Text("Tag: \(tag)")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(item.id)
                    .contextMenu {
                        Button("Refresh") {
                            Task { await refresh(item) }
                        }
                    }
                }
                .onDelete(perform: deleteWorkItems)
            }
            .navigationTitle("Work Items")
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        showingNewWorkItem = true
                    } label: {
                        Label("New Work Item", systemImage: "plus")
                    }

                    Button {
                        Task { await refreshAll() }
                    } label: {
                        Label("Refresh All", systemImage: "arrow.clockwise")
                    }
                }
            }
        } detail: {
            if let selectedWorkItem {
                WorkItemDetailView(
                    item: selectedWorkItem,
                    onRefresh: { Task { await refresh(selectedWorkItem) } },
                    onCreateDeploymentPR: { Task { await createDeploymentPR(for: selectedWorkItem) } }
                )
            } else {
                ContentUnavailableView(
                    "Select a work item",
                    systemImage: "sidebar.left",
                    description: Text("You can also create a new item from the toolbar.")
                )
            }
        }
        .sheet(isPresented: $showingNewWorkItem) {
            NewWorkItemSheet(existingBranches: workItems.map { $0.localBranch }) { message in
                statusMessage = message
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppEvents.refreshAll)) { _ in
            Task { await refreshAll(fromAutoRefresh: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppEvents.openNewWorkItem)) { _ in
            showingNewWorkItem = true
        }
        .onReceive(autoRefreshTimer) { _ in
            guard autoRefreshEnabled else { return }
            Task { await refreshAll(fromAutoRefresh: true) }
        }
        .safeAreaInset(edge: .bottom, alignment: .leading) {
            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
        .task {
            NotificationService.requestAuthorizationIfNeeded()
        }
    }

    private func refreshAll(fromAutoRefresh: Bool = false) async {
        for item in workItems {
            await refresh(item, updateStatusMessage: false)
        }
        statusMessage = fromAutoRefresh
            ? "Auto-refreshed \(workItems.count) item(s)."
            : "Refreshed \(workItems.count) item(s)."
    }

    private func refresh(_ item: WorkItem, updateStatusMessage: Bool = true) async {
        let token = KeychainService.loadGitHubToken().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            item.lastErrorMessage = "GitHub PAT is not configured. Add it in Settings."
            item.lastSyncedAt = .now
            item.updatedAt = .now
            if updateStatusMessage { statusMessage = "Missing GitHub PAT." }
            return
        }

        do {
            let previousPRState = item.prState
            let previousCheckState = item.checkState
            let previousReviewCount = item.reviewRequestedCount
            let previousIssueCommentCount = item.issueCommentCount
            let previousReviewCommentCount = item.reviewCommentCount

            let pullRequest = try await GitHubClient.fetchPullRequest(
                repoFullName: item.sourceRepoFullName,
                headBranch: item.localBranch,
                token: token
            )

            if let pullRequest {
                item.prNumber = pullRequest.number
                item.prURL = pullRequest.url
                item.headSHA = pullRequest.headSHA
                item.prState = derivePRState(from: pullRequest)
                item.checkState = try await GitHubClient.fetchCheckState(
                    repoFullName: item.sourceRepoFullName,
                    commitSHA: pullRequest.headSHA,
                    token: token
                )

                let signals = try await GitHubClient.fetchPullRequestSignals(
                    repoFullName: item.sourceRepoFullName,
                    prNumber: pullRequest.number,
                    token: token
                )
                item.reviewRequestedCount = signals.reviewRequestedCount
                item.issueCommentCount = signals.issueCommentCount
                item.reviewCommentCount = signals.reviewCommentCount

                notifyForStateChanges(
                    item: item,
                    previousPRState: previousPRState,
                    previousCheckState: previousCheckState,
                    previousReviewCount: previousReviewCount,
                    previousIssueCommentCount: previousIssueCommentCount,
                    previousReviewCommentCount: previousReviewCommentCount
                )

                if item.prState == .merged {
                    try await resolveTagIfNeeded(for: item, token: token, fallbackBranch: pullRequest.baseBranch)
                }
            } else {
                item.prNumber = nil
                item.prURL = nil
                item.headSHA = nil
                item.prState = .noPR
                item.checkState = .unknown
            }

            item.lastErrorMessage = nil
        } catch {
            item.lastErrorMessage = error.localizedDescription
        }

        item.lastSyncedAt = .now
        item.updatedAt = .now
        if updateStatusMessage { statusMessage = "Refreshed \(item.ticketID)." }
    }

    private func resolveTagIfNeeded(for item: WorkItem, token: String, fallbackBranch: String) async throws {
        guard item.latestTag == nil else { return }
        guard let sourceRepo = sourceRepos.first(where: { $0.repoFullName == item.sourceRepoFullName }) else { return }

        let branch = sourceRepo.defaultTargetBranch.isEmpty ? fallbackBranch : sourceRepo.defaultTargetBranch
        let result = try await WorkflowTagResolver.resolveTag(
            repoFullName: sourceRepo.repoFullName,
            workflowIdentifier: sourceRepo.workflowIdentifier,
            branch: branch,
            token: token
        )
        item.latestTag = result.tag
    }

    private func notifyForStateChanges(
        item: WorkItem,
        previousPRState: PRState,
        previousCheckState: CheckState,
        previousReviewCount: Int,
        previousIssueCommentCount: Int,
        previousReviewCommentCount: Int
    ) {
        if notifyMerged, previousPRState != .merged, item.prState == .merged {
            NotificationService.notify(title: "PR merged", body: "\(item.ticketID) merged successfully.")
        }

        if notifyChecksFailed, previousCheckState != .failing, item.checkState == .failing {
            NotificationService.notify(title: "Checks failed", body: "\(item.ticketID) has failing checks.")
        }

        if notifyReviewRequested, item.reviewRequestedCount > previousReviewCount {
            NotificationService.notify(title: "Review requested", body: "\(item.ticketID) has a new review request.")
        }

        if notifyPRComments {
            let hasNewIssueComments = item.issueCommentCount > previousIssueCommentCount
            let hasNewReviewComments = item.reviewCommentCount > previousReviewCommentCount
            if hasNewIssueComments || hasNewReviewComments {
                NotificationService.notify(title: "New PR comments", body: "\(item.ticketID) received new PR comments.")
            }
        }
    }

    private func createDeploymentPR(for item: WorkItem) async {
        let token = KeychainService.loadGitHubToken().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            statusMessage = "Missing GitHub PAT."
            return
        }

        guard let deploymentRepo = deploymentRepos.first else {
            statusMessage = "Configure deployment repo in Settings first."
            return
        }

        do {
            let result = try await DeploymentConfigUpdater.updateAndOpenPullRequest(
                deploymentRepo: deploymentRepo,
                workItem: item,
                token: token
            )
            item.deploymentPRURL = result.pullRequestURL
            item.updatedAt = .now
            statusMessage = "Created deployment PR for \(item.ticketID)."
        } catch {
            item.lastErrorMessage = error.localizedDescription
            statusMessage = "Failed deployment update for \(item.ticketID)."
        }
    }

    private func derivePRState(from pullRequest: PullRequestSummary) -> PRState {
        if pullRequest.mergedAt != nil {
            return .merged
        }
        switch pullRequest.state {
        case "open": return .open
        case "closed": return .closed
        default: return .noPR
        }
    }

    private func deleteWorkItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(workItems[index])
            }
        }
        statusMessage = "Deleted \(offsets.count) item(s)."
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [WorkItem.self, SourceRepoConfig.self, DeploymentRepoConfig.self], inMemory: true)
}
