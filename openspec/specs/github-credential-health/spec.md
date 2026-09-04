# github-credential-health Specification

## Status

status: active

## Purpose
TBD - created by archiving change tray-responsiveness-and-startup-gating. Update Purpose after archive.
## Requirements
### Requirement: Credential health probe distinguishes "down" from "unauthenticated"
<!-- req-id: 98e5e9d5 -->

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
<!-- req-id: c33e363b -->

The probe MUST execute on a spawned task with a 10-second budget. Timeouts reclassify as `GithubUnreachable`, not `CredentialInvalid`.

#### Scenario: Probe hang does not stall the UI
- **WHEN** `api.github.com` is reachable but silent (packet drop mid-handshake)
- **THEN** the probe future's `tokio::time::timeout(10s, ...)` fires
- **AND** the result is recorded as `GithubUnreachable`
- **AND** the event loop never blocked waiting for it
- **AND** Quit/Language responded normally during the probe

### Requirement: Result is cached per process lifetime but invalidated on explicit sign-in / sign-out
<!-- req-id: 09fcfb2f -->

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


### Requirement: A credential that goes bad IN PLACE is observed without a presence transition
<!-- req-id: b39297a1 -->


<!-- @trace order:995-srbf, spec:github-credential-health -->

Every trigger in the requirements above is a TRANSITION: the tray starting, a
sign-in, a sign-out, a token appearing or disappearing from the store. A token
that expires or is revoked while sitting in place crosses none of them. This
requirement covers that case, which produced a measured 22-hour window in which
a present-and-refused token was rendered as `Authenticated`.

The guest-side login poll SHALL obtain a VALIDATING observation of the
credential on a bounded cadence, independent of any change in token PRESENCE. A
presence check MUST NOT be treated as a validity check: presence answers "is
there a token", and the state table above is defined entirely in terms of what
the API said.

The validating observation MUST distinguish a credential the API REFUSED from a
probe that obtained NO ANSWER, and only the first may demote. A probe that could
not run says nothing about the credential; demoting on it logs the operator out
over a transient container or network fault, which is a more visible failure
than the stale state this requirement exists to prevent.

A probe that repeatedly obtains no answer MUST NOT be silent. An indefinitely
broken probe is otherwise indistinguishable from a healthy one — the exact
shape of the defect this requirement addresses.

#### Scenario: A token revoked mid-session demotes without any presence change
- **WHEN** the tray has been running with a valid token and the token is revoked at GitHub
- **AND** the token remains present in Vault, so presence never changes
- **THEN** the next validating observation classifies it `CredentialInvalid`
- **AND** the tray demotes to the GitHub login leaf
- **AND** the demotion required no restart, no sign-out, and no token removal

#### Scenario: A probe that cannot run does not log the operator out
- **WHEN** the validating probe fails because the container runtime, image, proxy or network is unavailable
- **THEN** the classification is `GithubUnreachable`
- **AND** the login state is left exactly as it was
- **AND** the failure is logged with its reason and a consecutive-failure count

#### Scenario: Revalidation stays off the hot path
- **WHEN** the login poll is running with a subscriber attached to a Ready VM
- **THEN** the validating probe runs at a multiple of the heavy tick, not on the fast tick
- **AND** an idle headless with no subscriber runs no validating probe at all

### Requirement: The implemented vocabulary is named, and the tray-loop polling ban is scoped
<!-- req-id: a15921a9 -->



<!-- @trace order:995-srbf, spec:github-credential-health -->

SUPERSEDES, without removing, the clause in "Result is cached per process
lifetime" that reads "Background re-probing every N seconds is forbidden". That
clause cites the `spec:tray-app` responsiveness invariant, whose subject is the
TRAY EVENT LOOP. It is preserved with that scope: the tray event loop still
performs no credential polling. The guest-side headless is not the tray loop and
already polls there; the validating observation rides that existing cadence, off
the event loop, and the responsiveness invariant is untouched.

Stating the ban unscoped is what made the honest fix look prohibited. The
requirement it protects is responsiveness, not staleness — and taken literally
it forbade the only mechanism that can observe a mid-session expiry at all.

STATE VOCABULARY, RECONCILED. The four names in the table above appeared nowhere
in `crates/` when this was written: an active spec whose classifier vocabulary
had no implementation. The implemented type is
`remote_projects::CredentialObservation`, and this is its mapping — the spec
names what exists, rather than naming four states and leaving a reader to assume
they are implemented:

| Spec state | Implemented as |
|---|---|
| `Authenticated` | `CredentialObservation::Valid(login)` — the API answered with an account handle |
| `CredentialMissing` | `CredentialObservation::Invalid("no-token-in-vault")` |
| `CredentialInvalid` | `CredentialObservation::Invalid("api-rejected-credential")` — HTTP 401/403 |
| `GithubUnreachable` | `CredentialObservation::Unreachable(reason)` — every no-answer class, including a probe that never ran |

`CredentialMissing` and `CredentialInvalid` collapse to one variant carrying a
reason because the state table gates them IDENTICALLY (project lists disabled,
login as the primary call-to-action). The distinction is preserved in the reason
string, which is what reaches the log, rather than in a variant nothing branches
on.

#### Scenario: The spec's vocabulary is checkable against the code
- **WHEN** a reader looks for the classifier named in this spec
- **THEN** `CredentialObservation` exists in `crates/tillandsias-headless/src/remote_projects.rs`
- **AND** each of its variants is reachable from the verdict the containerized probe emits

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:credential-isolation` — Verify token isolation and probe classification accuracy

Gating points:
- Probe classifies a valid token as `Authenticated` with HTTP 200 from GitHub API
- Probe classifies missing token as `CredentialMissing` (no network call made)
- Probe classifies HTTP 401 as `CredentialInvalid`, not `GithubUnreachable`
- Probe with network timeout (DNS, TCP, or 10-second budget) classifies as `GithubUnreachable`
- UI gating (projects DISABLED when `CredentialMissing`, ENABLED when `GithubUnreachable`)
- Probe cache is invalidated exactly once per user-initiated sign-in/sign-out (no polling)

## Sources of Truth

- `cheatsheets/utils/git-workflows.md` — Git Workflows reference and patterns
- `cheatsheets/runtime/unix-socket-ipc.md` — Unix Socket Ipc reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:github-credential-health" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
