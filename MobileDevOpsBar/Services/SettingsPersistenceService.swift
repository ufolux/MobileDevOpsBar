import Foundation
import SwiftData

private struct PersistedSettings: Codable {
    let schemaVersion: Int
    var sourceRepos: [PersistedSourceRepo]
    var deploymentRepos: [PersistedDeploymentRepo]
}

private struct PersistedSourceRepo: Codable {
    let repoURL: String
    let repoFullName: String
    let localPath: String
    let defaultTargetBranch: String
    let workflowIdentifier: String
}

private struct PersistedDeploymentRepo: Codable {
    let repoURL: String
    let repoFullName: String
    let localPath: String
    let selectedEnvironmentBranch: String
}

enum SettingsPersistenceService {
    private static let schemaVersion = 1
    private static let directoryName = "MobileDevOpsBar"
    private static let fileName = "settings-v1.json"

    @MainActor
    static func saveRepoSettings(modelContext: ModelContext) throws {
        let sourceRepos = try modelContext.fetch(FetchDescriptor<SourceRepoConfig>())
        let deploymentRepos = try modelContext.fetch(FetchDescriptor<DeploymentRepoConfig>())

        let payload = PersistedSettings(
            schemaVersion: schemaVersion,
            sourceRepos: sourceRepos.map {
                PersistedSourceRepo(
                    repoURL: $0.repoURL,
                    repoFullName: $0.repoFullName,
                    localPath: $0.localPath,
                    defaultTargetBranch: $0.defaultTargetBranch,
                    workflowIdentifier: $0.workflowIdentifier
                )
            },
            deploymentRepos: deploymentRepos.map {
                PersistedDeploymentRepo(
                    repoURL: $0.repoURL,
                    repoFullName: $0.repoFullName,
                    localPath: $0.localPath,
                    selectedEnvironmentBranch: $0.selectedEnvironmentBranch
                )
            }
        )

        let fileURL = try settingsFileURL()
        let data = try JSONEncoder.pretty.encode(payload)
        try data.write(to: fileURL, options: .atomic)
    }

    @MainActor
    static func restoreRepoSettingsIfNeeded(modelContext: ModelContext) throws {
        let sourceRepoCount = try modelContext.fetchCount(FetchDescriptor<SourceRepoConfig>())
        let deploymentRepoCount = try modelContext.fetchCount(FetchDescriptor<DeploymentRepoConfig>())
        guard sourceRepoCount == 0, deploymentRepoCount == 0 else {
            return
        }

        let fileURL = try settingsFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(PersistedSettings.self, from: data)

        guard decoded.schemaVersion == schemaVersion else {
            return
        }

        for repo in decoded.sourceRepos {
            let sourceRepo = SourceRepoConfig(
                repoURL: repo.repoURL,
                repoFullName: repo.repoFullName,
                localPath: repo.localPath,
                defaultTargetBranch: repo.defaultTargetBranch,
                workflowIdentifier: repo.workflowIdentifier
            )
            modelContext.insert(sourceRepo)
        }

        for repo in decoded.deploymentRepos {
            let deploymentRepo = DeploymentRepoConfig(
                repoURL: repo.repoURL,
                repoFullName: repo.repoFullName,
                localPath: repo.localPath,
                selectedEnvironmentBranch: repo.selectedEnvironmentBranch
            )
            modelContext.insert(deploymentRepo)
        }
    }

    private static func settingsFileURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let settingsDirectory = appSupport.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        return settingsDirectory.appendingPathComponent(fileName)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
