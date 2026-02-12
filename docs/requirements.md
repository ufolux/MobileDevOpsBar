# MobileDevOpsBar Requirements

## Product Goal
Build a macOS desktop tool (menu bar + dashboard) to support daily development workflow from ticket intake through deployment config PR updates.

## Primary Workflow
1. Input Rally ticket IDs (stories and defects).
2. Create local git branches from ticket IDs.
3. Detect PRs automatically from branches.
4. Notify on PR changes (merged, checks failed, review requested, comments).
5. After merge, resolve latest build tag from GitHub Actions workflow logs.
6. Update deployment config in another repo and open a PR.

## Fixed Decisions
- App UX: menu bar + dashboard window.
- Refresh behavior:
  - Manual refresh always available.
  - Optional auto refresh every 20 minutes (default OFF).
- Auth: GitHub PAT stored in Keychain.
- Repos are configurable by pasting GitHub repo URL.
- Repo settings persist across app reinstall by storing non-secret settings in
  `~/Library/Application Support/MobileDevOpsBar/settings-v1.json`.

## Branch Rules
- Ticket formats:
  - Story: `US<digits>`
  - Defect: `DE<digits>`
- Naming:
  - `US123` -> `feature/starship/US123-{sequence}`
  - `DE123` -> `fix/starship/DE123-{sequence}`
- Sequence policy: per-ticket increment (`US123-1`, `US123-2`, ...).

## PR Tracking
- PRs linked by source repo + head branch (auto-detect, no manual URL required).
- Source PRs can also be created from within the app by selecting a target/base branch.
- Notification events:
  - PR merged
  - checks failed
  - review requested
  - issue comments on PR thread
  - review comments on code lines

## Build Tag Extraction
- Source: specific configured GitHub Actions workflow.
- Locate in workflow run:
  - job: `build-and-publish`
  - step: `Push Artifact (Gated)`
- Parse log line format: `New Tag is {tag}`
- Extracted `{tag}` is the deployment version value.

## Deployment Config Update
- Deployment repo is user-configured by URL.
- Environment branches: `qa` and `dev`.
  - Default environment branch: `qa`.
  - User can switch to `dev` per setup/update.
- Config target:
  - file: `.circleci/config.yml`
  - key path: `parameters.DEPLOY_TAG.default`
- Update flow:
  - create branch: `chore/update-mobile-tag-{tag}`
  - commit config change
  - open PR in deployment repo
  - title: `chore: update mobile deployment tag to {tag}`

## MVP Screens
1. Menu bar popover
2. Dashboard work-item list and detail
3. New Work Item modal
4. Settings (auth + repos + workflow + refresh)
5. Activity log (phase 2)

## Rally Link
- Settings provides Rally URL template support.
- Template supports `{ticketnumber}` placeholder.
- Work item detail shows a clickable Rally link when template is configured.

## Implementation Phases
1. App shell + data models + settings + keychain.
2. Ticket parsing + branch generation + local branch creation.
3. PR auto-detect + refresh engine + notification state tracking.
4. Workflow log parsing for tag extraction.
5. Deployment config updater + PR creation.
6. Hardening: retries, errors, activity timeline, UX polish.
