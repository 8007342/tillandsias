## MODIFIED Requirements

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
