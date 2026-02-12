import SwiftUI
import SwiftData

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \WorkItem.updatedAt, order: .reverse) private var workItems: [WorkItem]
    @AppStorage("autoRefreshEnabled") private var autoRefreshEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mobile DevOps")
                .font(.headline)

            Text("Work items: \(workItems.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Auto refresh: \(autoRefreshEnabled ? "20m" : "Off")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Button("New Work Item") {
                openWindow(id: "dashboard")
                NotificationCenter.default.post(name: AppEvents.openNewWorkItem, object: nil)
            }

            Button("Refresh All") {
                NotificationCenter.default.post(name: AppEvents.refreshAll, object: nil)
            }

            Button("Open Dashboard") {
                openWindow(id: "dashboard")
            }

            SettingsLink {
                Text("Open Settings")
            }

            Divider()

            ForEach(workItems.prefix(5)) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.ticketID)
                        .font(.caption)
                    Text(item.prState.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}
