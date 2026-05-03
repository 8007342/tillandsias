# github-credential-health Specification

## Status

status: active

## Purpose
TBD - created by archiving change tray-responsiveness-and-startup-gating. Update Purpose after archive.
## Requirements
### Requirement: Credential health probe distinguishes "down" from "unauthenticated"

The tray SHALL run a GitHub credential health probe on startup and cache its classified result. The probe MUST classify every failure into exactly one of these states:

| State | Triggers |
|---|---|
| `Authenticated` | HTTP 200 from `GET api.github.com/user` with a current token, OR `gh auth status` exits 0 with scopes that include `repo` |
| `CredentialMissing` | No token in the OS keyring, OR `gh auth status` reports "not logged in" |
| `CredentialInvalid` | HTTP 401, HTTP 403 with invalid-token message, OR `gh auth status` reports token revoked / scope mismatch |
| `GithubUnreachable` | DNS failure, TCP connect timeout, TLS error, HTTP 5xx, HTTP 429, or any other transient network class |

The classification SHALL drive downstream UI gating:

- `Authenticated` → project lists + Attach Here enabled.
- `CredentialMissing` / `CredentialInvalid` → project lists DISABLED, GitHub login surfaced as the primary call-to-action. Tray DOES NOT proceed past this gate.
- `GithubUnreachable` → project lists ENABLED with a "cached/offline" banner; remote-repo list served from last-successful-fetch cache; commits continue to flow mirror → GitHub once connectivity returns.

#### Scenario: Offline laptop keeps working
- **WHEN** the tray starts on a laptop with no network connectivity but a previously-valid token in the keyring
- **AND** the probe fails with `connect: network is unreachable`
- **THEN** the classification is `GithubUnreachable`, not a credential error
- **AND** the tray enables project lists (from cache)
- **AND** Attach Here works: the forge clones from the local git-service mirror (which already has the project)
- **AND** commits flow to the mirror; post-receive retry-push fails harmlessly; stays queued until connectivity returns

#### Scenario: Expired token refuses launch
- **WHEN** the tray starts and the token in the keyring returns HTTP 401 from `api.github.com/user`
- **THEN** the classification is `CredentialInvalid`
- **AND** Remote projects, Local projects, and Attach Here are all disabled
- **AND** the tray surfaces "Sign in to GitHub" as the primary menu action
- **AND** Quit + Language remain enabled

#### Scenario: Never-authed install gates access
- **WHEN** the tray starts on a host with no token in the keyring
- **THEN** the classification is `CredentialMissing`
- **AND** project lists stay disabled with tooltip "sign in to GitHub to list projects"
- **AND** GitHub login is offered as the only actionable menu item (plus Exit/Language)

### Requirement: Probe runs off the event loop with a bounded timeout

The probe MUST execute on a spawned task with a 10-second budget. Timeouts reclassify as `GithubUnreachable`, not `CredentialInvalid`.

#### Scenario: Probe hang does not stall the UI
- **WHEN** `api.github.com` is reachable but silent (packet drop mid-handshake)
- **THEN** the probe future's `tokio::time::timeout(10s, ...)` fires
- **AND** the result is recorded as `GithubUnreachable`
- **AND** the event loop never blocked waiting for it
- **AND** Quit/Language responded normally during the probe

### Requirement: Result is cached per process lifetime but invalidated on explicit sign-in / sign-out

The probe result SHALL be cached for the tray process's lifetime and only re-run on:

- User-initiated "Sign in to GitHub" action.
- User-initiated "Sign out" action.
- Token in the keyring changes (detected via the existing `secrets_management` watcher, if any; otherwise on next user-initiated refresh).

Background re-probing every N seconds is forbidden (`spec:tray-app` responsiveness invariant — no polling in the tray loop).

#### Scenario: User signs in after a failed probe
- **WHEN** the initial probe classified as `CredentialMissing`
- **AND** the user completes the "Sign in to GitHub" flow
- **THEN** the probe re-runs exactly once
- **AND** the new classification replaces the cached one
- **AND** UI gating advances to the new state


## Sources of Truth

- `cheatsheets/utils/git-workflows.md` — Git Workflows reference and patterns
- `cheatsheets/runtime/unix-socket-ipc.md` — Unix Socket Ipc reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:github-credential-health" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
