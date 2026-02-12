import Foundation
import SwiftData

@Model
final class DeploymentRepoConfig {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var repoFullName: String
    var repoURL: String
    var localPath: String
    var selectedEnvironmentBranch: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        repoURL: String,
        repoFullName: String,
        localPath: String,
        selectedEnvironmentBranch: String = "qa",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.repoURL = repoURL
        self.repoFullName = repoFullName
        self.localPath = localPath
        self.selectedEnvironmentBranch = selectedEnvironmentBranch
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static let configFilePath = ".circleci/config.yml"
    static let deployTagKeyPath = "parameters.DEPLOY_TAG.default"
}
