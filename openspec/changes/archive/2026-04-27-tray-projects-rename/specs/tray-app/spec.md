## MODIFIED Requirements

### Requirement: Projects and Remote Projects render as sibling top-level submenus

When the credential probe is `Authenticated` (or `NetIssue` with cached projects available), local and remote projects SHALL render as two sibling top-level submenus. Their labels SHALL be `🏠 ~/src ▸` (local watch-path projects) and `☁️ Cloud ▸` (uncloned GitHub repos). The labels MUST carry the emoji prefix so users can visually distinguish "what's on disk" from "what's in the cloud" at a glance.

Each submenu is appended to the menu only when it would have at least one entry — empty submenus SHALL NOT appear.

The previous `Include remote` `CheckMenuItem` inside `Projects ▸` SHALL NOT exist. Its event variant `MenuCommand::IncludeRemoteToggle` SHALL be removed.

#### Scenario: Both submenus appear when both have entries
- **WHEN** `state.projects` is non-empty AND `state.remote_repos` contains at least one repo not present locally
- **THEN** the menu SHALL contain `🏠 ~/src ▸` and `☁️ Cloud ▸` as sibling top-level submenus
- **AND** clicking inside either submenu SHALL NOT cause the other to rebuild or flicker

#### Scenario: Only local submenu appears when no uncloned remotes
- **WHEN** `state.projects` is non-empty AND every repo in `state.remote_repos` is already cloned locally
- **THEN** the menu SHALL contain `🏠 ~/src ▸`
- **AND** the menu SHALL NOT contain `☁️ Cloud ▸` (not even as a disabled or empty row)

#### Scenario: Only cloud submenu appears when no local projects
- **WHEN** `state.projects` is empty AND `state.remote_repos` contains at least one repo
- **THEN** the menu SHALL contain `☁️ Cloud ▸`
- **AND** the menu SHALL NOT contain `🏠 ~/src ▸` (not even as a disabled or empty row)

#### Scenario: Clicking a cloud project clones and launches
- **WHEN** the user clicks a repo under `☁️ Cloud ▸ → <repo-name>`
- **THEN** the tray dispatches `MenuCommand::CloneProject { full_name, name }`
- **AND** the existing `handle_clone_project` flow runs — clone into the watch path, pre-insert the project into `state.projects`, then call `handle_attach_here` to launch the forge
- **AND** the project subsequently appears under `🏠 ~/src ▸` (no longer in `☁️ Cloud ▸`)

### Requirement: Tray menu has a fixed five-stage state machine

The tray SHALL render exactly one of five menu states at any moment.
The state machine MUST be deterministic — given the (`enclave_health`,
`credential_health`, `remote_repo_fetch_status`) triple there is one
correct stage.

| Stage      | Trigger                                                          | Visible items |
|------------|------------------------------------------------------------------|---------------|
| `Booting`  | Tray just started; one or more enclave images still building     | contextual status line (`Building […]…`), divider, `v<version> — by Tlatoāni` (disabled), `Quit Tillandsias` |
| `Ready`    | All enclave images ready; before the credential probe completes  | optional contextual status line (`<image> ready`, only within 2s flash window), divider, `v<version> — by Tlatoāni` (disabled), `Quit Tillandsias` |
| `NoAuth`   | Credential probe returned `CredentialMissing` or `CredentialInvalid` | `🔑 Sign in to GitHub` (enabled action), divider, `v<version> — by Tlatoāni` (disabled), `Quit Tillandsias` |
| `Authed`   | Credential probe returned `Authenticated` and remote-repo fetch succeeded (or local-only) | running-stack submenus (zero or more), `🏠 ~/src ▸` (only if non-empty), `☁️ Cloud ▸` (only if non-empty), divider, `v<version> — by Tlatoāni` (disabled), `Quit Tillandsias` |
| `NetIssue` | Credential probe returned `GithubUnreachable` (or remote fetch failed transiently) | `🔑 Sign in to GitHub` (enabled action), contextual status line (`GitHub unreachable — using cached list`), running-stack submenus, `🏠 ~/src ▸` (only if non-empty), divider, `v<version> — by Tlatoāni` (disabled), `Quit Tillandsias` |

`Quit Tillandsias` SHALL appear in every stage and SHALL always be enabled. The single combined `v<version> — by Tlatoāni` line SHALL appear in every stage immediately above `Quit Tillandsias` and SHALL always be disabled (visual signature only). The `Language ▸` submenu SHALL NOT appear in any stage; the locale defaults to `en` until i18n is re-enabled in a future change. No other disabled item SHALL appear in any stage except the contextual status line described above.

#### Scenario: Version + signature persist across all stages
- **WHEN** the tray transitions between any two stages (e.g.,
  `Booting` → `Authed`)
- **THEN** the single combined signature row `v<version> — by Tlatoāni` SHALL remain visible immediately above `Quit Tillandsias`
- **AND** the signature row SHALL be disabled (no click handler)
- **AND** its text SHALL not change between stages

#### Scenario: Booting → Ready transition
- **WHEN** the last of the enclave images (forge / proxy / git /
  inference / router) reports ready
- **THEN** the menu transitions from `Booting` to `Ready`
- **AND** the contextual status line shows the transient `<image> ready` text for at most 2 seconds, then is removed
- **AND** the credential probe is kicked off in the background

#### Scenario: Ready → NoAuth transition
- **WHEN** the credential probe returns `CredentialMissing` or
  `CredentialInvalid`
- **THEN** any transient status line is removed and `🔑 Sign in to GitHub` is appended as an enabled action
- **AND** no `🏠 ~/src ▸` or `☁️ Cloud ▸` submenu is appended

#### Scenario: Ready → Authed transition
- **WHEN** the credential probe returns `Authenticated`
- **AND** the remote-repo fetch succeeds (or the user has chosen
  local-only)
- **THEN** any running-stack submenus are appended at the top
- **AND** `🏠 ~/src ▸` is appended if `state.projects` is non-empty
- **AND** `☁️ Cloud ▸` is appended if any remote repo is not yet cloned locally

#### Scenario: NetIssue offers cached projects
- **WHEN** the host has previously fetched a remote project list and
  the latest probe returned `GithubUnreachable`
- **THEN** `🏠 ~/src ▸` SHALL still populate from the on-disk cache
- **AND** the contextual status line SHALL include `GitHub unreachable — using cached list`
- **AND** the `🔑 Sign in to GitHub` action SHALL be present (enabled) so the user can retry

#### Scenario: Language submenu is hidden in all stages
- **WHEN** the menu is open in any of the five stages
- **THEN** the menu SHALL NOT contain a `Language ▸` submenu
- **AND** the static row at the bottom is exactly `[separator] [v<version> — by Tlatoāni] [Quit Tillandsias]`

## ADDED Requirements

### Requirement: Locale defaults to en until i18n is re-enabled

The `i18n::initialize` (or equivalent locale-selection function) SHALL hard-code the active locale to `"en"` regardless of `LANG`, `LC_ALL`, OS settings, or saved user preference. The locale-loading pipeline (embedded `.toml` files, `i18n::t` / `i18n::tf` lookups, `STRINGS` table) SHALL remain functional so a one-line change in `initialize` re-enables locale selection later. The `MenuCommand::SelectLanguage` event variant SHALL remain in the enum (the dispatch path stays valid; only the menu item that emits it is removed).

#### Scenario: Locale is en regardless of OS settings
- **WHEN** the tray starts on a host with `LANG=fr_FR.UTF-8`
- **THEN** `i18n::current_language()` returns `"en"`
- **AND** `i18n::t("menu.quit")` returns the English value `"Quit Tillandsias"`

#### Scenario: i18n pipeline still functional
- **WHEN** code calls `i18n::tf("menu.signature_with_version", &[("version", "0.1.169.227")])`
- **THEN** the result is a non-empty string with the version interpolated
- **AND** the call does not panic or return an error

#### Scenario: Re-enabling is a one-line change
- **WHEN** a future contributor wants to bring the Language submenu back
- **THEN** they SHALL only need to (a) revert the `initialize` hard-code to call the OS-detection helper that is preserved as a tombstoned function, and (b) un-tombstone the `.item(&self.language)` line in `apply_state`
- **AND** no other code change is required to restore the previous behaviour

## Sources of Truth

- `cheatsheets/runtime/forge-container.md` — the `~/src` watch path that the new local-projects label cites.
- `cheatsheets/agents/openspec.md` — the workflow this change goes through.
