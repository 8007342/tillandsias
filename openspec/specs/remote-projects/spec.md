<!-- @trace spec:remote-projects -->
# remote-projects Specification

## Status

status: active

## Purpose
TBD - created by archiving change remote-project-clone. Update Purpose after archive.
## Requirements
### Requirement: Fetch remote repository list

The application SHALL fetch the authenticated user's GitHub repositories using the `gh` CLI inside a forge container. When credentials are missing or the API call fails, the failure SHALL be reflected in the contextual status line at the top of the tray menu (per `tray-app` spec) — there SHALL NOT be a disabled placeholder row inside `Remote Projects ▸`.

#### Scenario: Authenticated user with repos
- **WHEN** the remote projects list is requested and valid GitHub credentials exist
- **THEN** the application runs `gh repo list --json name,url --limit 100` in a forge container and returns the parsed list

#### Scenario: No GitHub credentials
- **WHEN** the remote projects list is requested and no GitHub credentials exist
- **THEN** the list is empty
- **AND** the `Remote Projects ▸` submenu SHALL NOT appear in the tray menu (no `Login to GitHub first` placeholder)
- **AND** the `🔑 Sign in to GitHub` action SHALL be visible at the top of the menu (per `tray-app` spec) so the user can resolve the missing credential

#### Scenario: GitHub API error
- **WHEN** the `gh repo list` command fails (network error, token expired)
- **THEN** the `Remote Projects ▸` submenu SHALL NOT appear in the tray menu (no `Could not fetch repos` placeholder)
- **AND** the contextual status line at the top of the menu MAY surface the network/auth condition (e.g., `GitHub unreachable — using cached list` when the cause is a network failure with cached projects available)

### Requirement: Filter against local projects
The remote repository list SHALL exclude repositories that already exist as local directories under the scanner's watched directory.

#### Scenario: Repo exists locally
- **WHEN** a GitHub repo named "tillandsias" is in the remote list and `~/src/tillandsias/` exists
- **THEN** "tillandsias" does not appear in the Remote Projects submenu

#### Scenario: Repo not present locally
- **WHEN** a GitHub repo named "new-project" is in the remote list and `~/src/new-project/` does not exist
- **THEN** "new-project" appears in the Remote Projects submenu

### Requirement: Cache remote repository list
The fetched repository list SHALL be cached in memory with a 5-minute TTL to avoid repeated API calls.

#### Scenario: Cache fresh
- **WHEN** the Remote Projects submenu is opened and the cache is less than 5 minutes old
- **THEN** the cached list is used without fetching from GitHub

#### Scenario: Cache stale
- **WHEN** the Remote Projects submenu is opened and the cache is more than 5 minutes old
- **THEN** a fresh list is fetched from GitHub and the cache is updated

#### Scenario: Cache refreshed after auth
- **WHEN** the user completes a GitHub Login or Refresh
- **THEN** the remote repo cache is invalidated and refreshed on next submenu open

### Requirement: Clone remote project
Clicking a remote project in the submenu SHALL clone it into the scanner's watched directory using the forge container.

#### Scenario: Successful clone
- **WHEN** the user clicks a remote project named "new-project"
- **THEN** `gh repo clone <owner>/new-project ~/src/new-project` runs inside a forge container
- **AND** the scanner detects the new directory and adds it to the project list
- **AND** the tray menu is rebuilt with the new project

#### Scenario: Clone in progress
- **WHEN** a clone operation is running
- **THEN** the Remote Projects submenu shows "Cloning <name>..." as a disabled item

#### Scenario: Clone failure
- **WHEN** the clone command fails
- **THEN** an error is logged and the menu reverts to the normal remote project list

### Requirement: Loading state
The Remote Projects submenu SHALL show a loading indicator while fetching the repository list.

#### Scenario: Fetching in progress
- **WHEN** the remote repo list is being fetched for the first time or after cache expiry
- **THEN** the submenu shows a disabled "Loading..." item


## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/architecture/event-driven-basics.md` — Event Driven Basics reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:remote-projects" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
