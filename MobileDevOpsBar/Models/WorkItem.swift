import Foundation
import SwiftData

enum PRState: String, CaseIterable, Codable {
    case noPR = "No PR"
    case open = "Open"
    case merged = "Merged"
    case closed = "Closed"
}

enum CheckState: String, CaseIterable, Codable {
    case unknown = "Unknown"
    case passing = "Passing"
    case failing = "Failing"
}

@Model
final class WorkItem {
    @Attribute(.unique) var id: UUID
    var ticketID: String
    var sourceRepoFullName: String
    var localBranch: String
    var prURL: String?
    var prNumber: Int?
    var headSHA: String?
    var lastErrorMessage: String?
    var prStateRaw: String
    var checkStateRaw: String
    var latestTag: String?
    var deploymentPRURL: String?
    var reviewRequestedCount: Int
    var issueCommentCount: Int
    var reviewCommentCount: Int
    var lastSyncedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        ticketID: String,
        sourceRepoFullName: String,
        localBranch: String,
        prURL: String? = nil,
        prNumber: Int? = nil,
        headSHA: String? = nil,
        lastErrorMessage: String? = nil,
        prState: PRState = .noPR,
        checkState: CheckState = .unknown,
        latestTag: String? = nil,
        deploymentPRURL: String? = nil,
        reviewRequestedCount: Int = 0,
        issueCommentCount: Int = 0,
        reviewCommentCount: Int = 0,
        lastSyncedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.ticketID = ticketID
        self.sourceRepoFullName = sourceRepoFullName
        self.localBranch = localBranch
        self.prURL = prURL
        self.prNumber = prNumber
        self.headSHA = headSHA
        self.lastErrorMessage = lastErrorMessage
        self.prStateRaw = prState.rawValue
        self.checkStateRaw = checkState.rawValue
        self.latestTag = latestTag
        self.deploymentPRURL = deploymentPRURL
        self.reviewRequestedCount = reviewRequestedCount
        self.issueCommentCount = issueCommentCount
        self.reviewCommentCount = reviewCommentCount
        self.lastSyncedAt = lastSyncedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var prState: PRState {
        get { PRState(rawValue: prStateRaw) ?? .noPR }
        set { prStateRaw = newValue.rawValue }
    }

    var checkState: CheckState {
        get { CheckState(rawValue: checkStateRaw) ?? .unknown }
        set { checkStateRaw = newValue.rawValue }
    }
}
