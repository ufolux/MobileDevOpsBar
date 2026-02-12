import Foundation
import SwiftData

@Model
final class SourceRepoConfig {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var repoFullName: String
    var repoURL: String
    var localPath: String
    var defaultTargetBranch: String
    var workflowIdentifier: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        repoURL: String,
        repoFullName: String,
        localPath: String,
        defaultTargetBranch: String = "main",
        workflowIdentifier: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.repoURL = repoURL
        self.repoFullName = repoFullName
        self.localPath = localPath
        self.defaultTargetBranch = defaultTargetBranch
        self.workflowIdentifier = workflowIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
