# MobileDevOpsBar Progress

## 2026-02-12

### Completed
- Captured finalized product requirements in `docs/requirements.md`.
- Replaced starter template data model with workflow-driven models:
  - `WorkItem`
  - `SourceRepoConfig`
  - `DeploymentRepoConfig`
- Added core utility/services:
  - ticket parsing (`US/DE` extraction)
  - branch name generation with per-ticket sequence
  - repo URL parsing (`owner/repo` normalization)
  - local git branch creation service
  - Keychain token storage service
- Implemented app shell structure:
  - dashboard window
  - menu bar extra
  - settings scene
- Implemented dashboard baseline:
  - work item listing
  - work item detail view
  - manual refresh (single + all)
  - create new work item flow
- Added menu bar quick actions:
  - open dashboard
  - open new work item modal
  - trigger refresh all
- Implemented settings baseline:
  - save GitHub PAT in Keychain
  - configure source repos by URL + local path + workflow
  - configure deployment repo by URL + local path + env branch (`qa`/`dev`)
  - optional auto-refresh toggle (20 minutes, default off)
- Wired optional 20-minute auto refresh timer to the dashboard refresh engine.
- Validated compilation with `xcodebuild` (Debug build succeeds).
- Implemented GitHub REST client scaffolding in `MobileDevOpsBar/Services/GitHubClient.swift`:
  - PR lookup by `repo + head branch`
  - commit status lookup for check state
- Wired async refresh flow in dashboard:
  - refresh now calls GitHub client
  - work item PR/check state updates are persisted
  - missing token and API failures are surfaced per item
- Extended work item model with PR metadata and refresh error storage.
- Implemented notification preference toggles and state-delta notifications:
  - merged
  - checks failed
  - review requested
  - PR comments (issue + review comments)
- Implemented workflow tag resolver:
  - resolves latest successful run for configured workflow
  - looks at `build-and-publish` job logs
  - validates presence of `Push Artifact (Gated)` and parses `New Tag is {tag}`
- Implemented deployment config updater + config PR flow:
  - updates `.circleci/config.yml`
  - updates `parameters.DEPLOY_TAG.default`
  - creates branch `chore/update-mobile-tag-{tag}`
  - commits/pushes and opens GitHub PR
- Added deployment PR trigger action in work item details.
- Revalidated compilation with `xcodebuild` (Debug build succeeds).

### In Progress
- End-to-end hardening (API edge cases, git failure recovery, and UX messaging).

### Next
- Add safeguards for dirty deployment repo working tree before auto-commit.
- Add richer activity timeline/history in dashboard.
- Add test coverage for parser and config update logic.
