# RESEARCH: auth/login flows as first-class finite state machines — the "login flow graph" (2026-07-23)

- **Class**: research (MANDATORY before implementation, operator standing rule)
- **Status**: proposed
- **Desired release**: future (v0.5+) — NOT blocking current v0.4/v0.3 work; durable direction
- **Owner host**: any (spans the shared `tillandsias-headless` login flow + `tillandsias-control-wire` + all three trays)
- **Operator vision (2026-07-23, The Tlatoāni, paraphrased)**: just as the container
  stack has a RUNTIME dependency graph ("I need that container running"), the GitHub
  login flow — and therefore every login/auth flow — needs its own **login flow graph**:
  a finite state machine documenting the stages of "I need this thing to happen there",
  i.e. what is possible and what is blocked. The FSM makes each stage an observable,
  named state instead of something inferred after the fact.
- **Motivating incident**: `plan/issues/macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md`
- **Sibling packets (non-overlapping, file together)**:
  - `plan/issues/research-unified-runtime-data-dependency-graph-2026-07-23.md` (the graph substrate this FSM's guards read: runtime + DATA nodes)
  - `plan/issues/research-flow-state-event-channel-2026-07-23.md` (the message-channel that carries this FSM's transitions as observable events)

## Motivation

The macOS GitHub login silently failed and was both **invisible** and **untraceable**.
The guest `tillandsias-headless --github-login`
(`crates/tillandsias-headless/src/main.rs` `run_provider_login`, `main.rs:6860`)
collects the operator's PAT and then must pass several fallible post-paste steps —
`gh auth status` (`main.rs:7024-7040`), then the in-container Vault write
(`main.rs:7051-7064`), then a Vault read-back verify (`main.rs:7066-7076`) — before the
token is actually persisted. If any pre-write step fails (gh egress / proxy / CA bundle,
per the field repro noted at `main.rs:6930-6938`), the process exits **before** the Vault
write: the PAT is collected but never persisted. The launcher wrapped the call as
`exec … || (…)`, so with `exec` the fallback branch was dead code and a non-zero exit
vanished with no message (`crates/tillandsias-host-shell/src/pty/mod.rs:216-222`,
since point-fixed).

The deeper defect is the one this packet targets: **nothing modeled "token collected →
token persisted → token verified" as named, observable states.** Login state is not
emitted by the flow at all — it is *inferred* after the fact by a periodic Vault
re-check (`remote_projects::probe_github_username`, `remote_projects.rs:384`;
`is_github_logged_in`, `remote_projects.rs:415`), folded into a binary `logged_in`
bool by `set_login_state` (`crates/tillandsias-headless/src/vsock_server.rs:252`). A
collected-but-not-persisted token is indistinguishable from "never started", so the
tray chip sits on "Logging In" forever. This is the recurring **whack-a-mole**: each
new failure point (egress, CA, proxy warm-up, vault write) is discovered only when it
breaks in the field, because the flow has no enumerated set of stages where a break can
be located.

A first-class FSM per auth flow converts "it silently didn't work" into "it is BLOCKED
at state `token_collected`, transition `persist_to_vault` failed, reason `ca_bundle`."

## Proposed model

Model each provider login as an explicit finite state machine — a `LoginFlow<Provider>`
— rather than a fire-and-forget imperative function that ends in a boolean.

**States (draft, GitHub-shaped; must generalize):**

| State | Meaning | Terminal? |
|---|---|---|
| `idle` | no login attempt in flight | yes (rest state) |
| `prereqs_pending` | ensuring enclave/egress/CA/Vault/Proxy (the dependency model) | no |
| `awaiting_operator` | interactive prompt open; PAT not yet pasted | no |
| `token_collected` | operator provided credential; not yet persisted | no |
| `token_persisted` | written to Vault (`secret/<provider>/token`) | no |
| `token_verified` | read-back + provider API accept (`gh api user`) | **yes (success)** |
| `blocked{stage, reason}` | a transition failed; carries the failing stage + stable reason | **yes (failure)** |
| `abandoned` | operator closed the prompt / timeout with no credential | yes |

**Transitions** are the fallible steps that already exist in `run_provider_login`,
each named and each able to resolve to `blocked{stage, reason}`:
`ensure_prereqs` (`main.rs:6890` via `ensure_git_login`) → `collect` (interactive
`gh auth login --with-token`, `main.rs:7022`) → `verify_session`
(`gh auth status`, `main.rs:7024-7040`) → `persist` (Vault write, `main.rs:7051-7064`)
→ `verify_persisted` (Vault read-back, `main.rs:7066-7076`).

**Blocked / possible predicates.** Each transition has a guard expressed against the
dependency graph (sibling packet ii): e.g. `persist` is *possible* iff
`data:vault_reachable` AND `data:ca_bundle_present`; otherwise it is *blocked* with a
stable reason. The FSM can therefore answer "what is possible / what is blocked right
now" without running the flow — which is exactly what the tray chip and diagnostics need.

**Generalization beyond GitHub.** The provider layer already abstracts this: `ProviderId`
with `vault_path()` / `secret_field()` / `id_str()` drives `run_provider_login` for
GitHub, Codex/OpenAI, OpenCode/Gemini, etc. (see the `ProviderId::GitHub => "secret/github/token"`
mapping at `main.rs:6691` and the provider-parameterised login container). The FSM is
therefore `LoginFlow<P: Provider>` with provider-specific *transitions* (some providers
use OAuth device flow, not `--with-token`) but the *same* state vocabulary. Codex's
outdated-assumptions history (`plan/issues/forge-agent-delegation-research-2026-07-19.md`,
Bug 1: injecting `OPENAI_API_KEY` silently suppresses the vault restore and authenticates
nothing) is a second instance of the same "no state told us it didn't take" class.

This packet defines the **states, transitions, and predicates**. It deliberately does
NOT define the transport (packet iii) or the underlying dependency-node substrate
(packet ii); it consumes both.

## Investigate / prototype

- **Enumerate the real transition set** from `run_provider_login` (`main.rs:6860-7120`)
  and confirm every early-return / `?` is mapped to exactly one `blocked{stage, reason}`.
  Are there fallible steps with no distinct reason today (collapsed into a generic
  `String` error)? List them.
- **Stable reason vocabulary.** Reuse the `.err.<reason>` codes proposed in
  `plan/issues/stable-state-codes-research-2026-07-05.md` (e.g. `auth.github.err.failed`,
  and finer: `err.ca_bundle`, `err.egress`, `err.vault_write`, `err.provider_reject`).
  Decide whether the FSM's `blocked` reason IS a stable-state-code or maps onto one.
- **Guard evaluation.** Should `possible/blocked` be computed lazily (evaluate guard on
  transition attempt) or eagerly (recompute the whole predicate set on every dependency
  change)? Prototype `is_possible(transition) -> Possible | Blocked(reason)` against the
  sibling-ii graph and measure cost.
- **Where does the FSM live?** A `login_flow` module in `tillandsias-headless` (guest-side,
  where the flow runs) vs. a shared crate so trays can render the same states. Note the
  existing precedent: `VmPhase` lives in `tillandsias-control-wire` precisely so both
  guest and host share one vocabulary (`control-wire/src/lib.rs:355`).
- **Interactive-step modeling.** `awaiting_operator` has no host-observable signal today
  (the PTY runs detached; the tray infers via grace-window + poll, see the incident's
  `LOGIN_STARTED_AT`/`LOGIN_GRACE` fixes). Prototype emitting a real
  `awaiting_operator` → `token_collected` transition from inside the flow so the tray
  stops guessing.
- **Idempotency & resumption.** If `persist` fails, can the flow resume from
  `token_collected` without re-prompting (the PAT is still in the ephemeral container)?
  Or is re-prompt mandatory? Decide and record — the incident's operator workaround
  ("quit and relaunch") is a manual resume today.
- **Reuse existing FSM machinery.** `tillandsias-control-wire` already ships FSM-shaped
  types: `GuestHealth` (`lib.rs:578`), `CrashLoopDetector` (`lib.rs:713`),
  `AutoResetPolicy` (`lib.rs:974`). Evaluate whether `LoginFlow` should follow the same
  in-crate pattern (typed states + a `feed(observation) -> transition` method).
- **Abandonment vs failure.** How does the FSM distinguish `abandoned` (operator closed
  the window) from `blocked` (a step errored)? The launcher point-fix now holds the
  window ~10s on non-zero exit; can that exit code disambiguate?

## Exit criteria

- A written FSM specification for at least GitHub AND one second provider (Codex or
  OpenCode) with: the full state set, the transition set, and for every transition a
  guard predicate expressed in terms of sibling-ii graph nodes.
- A falsifiable mapping table: **every** early-return / error path in
  `run_provider_login` (`main.rs:6860-7120`) maps to exactly one named `blocked{stage,
  reason}` — reviewers can check the table against the source with no gaps.
- A prototype `LoginFlow` type (behind a flag or in a scratch module) whose unit tests
  prove: (a) the collected-but-not-persisted incident lands in `blocked{persist, …}` and
  NOT in `idle`/`logged_out`; (b) `is_possible(persist)` returns `Blocked(ca_bundle)`
  when the CA-bundle node is unsatisfied; (c) a full happy path reaches `token_verified`.
- A decision record on: crate location, reason-code reuse vs. new vocabulary, guard
  eval strategy, and resume-vs-reprompt — enough that an implementation packet can be
  written without re-litigating the design.
- Explicit statement of which states are user-visible (drive the tray chip) vs.
  internal-only, consistent with `stable-state-codes-research-2026-07-05.md`.

## Existing-code references

- `crates/tillandsias-headless/src/main.rs:6860` — `run_provider_login` entry (the flow to be reified as an FSM).
- `crates/tillandsias-headless/src/main.rs:6890` — prereq bring-up via `ensure_git_login` (the `ensure_prereqs` transition; guards come from sibling ii).
- `crates/tillandsias-headless/src/main.rs:7022` — interactive `gh auth login --with-token` (the `collect` transition).
- `crates/tillandsias-headless/src/main.rs:7024-7040` — `gh auth status` (`verify_session`; a fallible post-paste gate).
- `crates/tillandsias-headless/src/main.rs:7051-7064` — Vault write (`persist`).
- `crates/tillandsias-headless/src/main.rs:7066-7076` — Vault read-back (`verify_persisted`).
- `crates/tillandsias-headless/src/main.rs:6691` — `ProviderId::GitHub => "secret/github/token"` (provider parameterisation → generalization axis).
- `crates/tillandsias-headless/src/remote_projects.rs:384` / `:415` — `probe_github_username` / `is_github_logged_in`: login state is *inferred by re-reading Vault*, not emitted by the flow.
- `crates/tillandsias-headless/src/vsock_server.rs:252` — `set_login_state`: collapses the whole flow into one `logged_in` bool.
- `crates/tillandsias-control-wire/src/lib.rs:355` — `VmPhase`: precedent for a shared, typed state vocabulary living in control-wire.
- `crates/tillandsias-control-wire/src/lib.rs:578,713,974` — `GuestHealth` / `CrashLoopDetector` / `AutoResetPolicy`: existing in-tree FSM machinery to imitate.
- `plan/issues/stable-state-codes-research-2026-07-05.md` — prior art: `auth.github.*` codes + `RuntimeStatusCode` enum this FSM's reasons should reuse.
- `plan/issues/macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md` — the motivating incident (root cause = lost token persistence, invisible + untraceable).
- `crates/tillandsias-host-shell/src/pty/mod.rs:216-222` — the `exec`-swallowed launcher wrapper that hid the failure (point-fixed; the FSM is the durable fix).

## Non-goals / scope

- NOT the transport/event mechanism — carrying these transitions over the wire is sibling
  packet iii (`research-flow-state-event-channel-2026-07-23.md`).
- NOT the dependency-node substrate — modeling `vault_reachable` / `ca_bundle_present` /
  `token_present` as graph nodes is sibling packet ii
  (`research-unified-runtime-data-dependency-graph-2026-07-23.md`); this packet only
  *reads* those nodes in its guards.
- NOT a tray-UX behavior change and NOT a v0.4 fix — the incident's point-fixes already
  shipped. This is the durable state model for v0.5+.
- NOT ZeroClaw / agent↔agent messaging (deleted as a critical violation; out of scope).
- NOT re-touching the Vault auth boundary or the pre-receive relay — the FSM observes
  those steps; it does not change their security posture.

## Transition map refreshed against source (2026-09-23, forge-tillandsias)

Partial slice of exit criterion 2 (the falsifiable mapping table). The line
numbers in the sections above date from 2026-07-23 and have all moved:
`run_provider_login` is now `main.rs` ~11029, not 6860. Cite the needles below
(function names and error strings), not line numbers.

### Execution order today (GitHub, Terminal lane)

Two changes since this packet was filed matter to the FSM:

- **Identity was placed between `collect` and `persist`** by 21243b4d3
  (2026-07-28, "token first, then git identity"). That brought back the
  collected-but-not-persisted class this packet was filed for. Filed and fixed
  as **1364-27f8** (work ref `work/1364-27f8` at 98cccfd7f, pending landing): identity now runs after `verify_persisted`, and the
  `--with-token` identity is read before `collect`.
- **The interactive `collect` exec has a wall-clock deadline.** Since
  2ac53a767 (order 714-4r6w) it runs through `run_podman_command`, which
  bounds it by `OperationKind::Container.default_budget()`, 300 s. That budget
  covers the human's time too: creating a fine-grained PAT, or finishing a
  device-code flow plus the in-container CLI install for Codex/Antigravity.
  714-4r6w criterion 3 already names this ("a deadline on the SETUP … and
  none on the human's typing") and is still open, so it is not re-filed here.
  For the FSM this is the case where `abandoned`, `blocked{collect, deadline}`
  and a slow operator all produce the same error today.

### Mapping table: every `?` / `Err` in `run_provider_login` → proposed stage and reason

Each row has a needle to grep in `run_provider_login`. "Distinct today?"
asks whether the error string alone tells a caller which stage failed.

| # | Needle (call site) | Proposed stage | Proposed reason | Distinct today? |
|---|---|---|---|---|
| 1 | `require_desktop_user_session(` | `ensure_prereqs` | `no_desktop_session` | yes (own message) |
| 2 | `resolve_existing_git_identity()?` (StdinToken, since 1364-27f8) | `ensure_prereqs` | `git_identity_missing` | yes |
| 3 | `resolve_runtime_asset_root(` | `ensure_prereqs` | `runtime_assets_missing` | yes |
| 4 | `ensure_image_exists(` | `ensure_prereqs` | `image_unavailable` | yes |
| 5 | `ensure_git_login(debug)?` (vault) / `ensure_enclave_network`+`ensure_proxy_running` (no vault) | `ensure_prereqs` | `dependency_down{node}` | partly: the dependency model names the node, the fallback chain does not |
| 6 | `check_auth_required_services(&["tillandsias-vault", "tillandsias-proxy"]` | `ensure_prereqs` | `service_unhealthy{name}` | yes |
| 7 | `mint_approle_secret_lease(` | `ensure_prereqs` | `vault_lease` | yes |
| 8 | `ensure_ca_bundle(debug)?` | `ensure_prereqs` | `ca_bundle` | yes |
| 9 | `run_podman_command_silent(run, debug)?` (helper start) | `ensure_prereqs` | `helper_start` | **no**: bare podman stderr |
| 10 | `check_auth_required_services(&required` | `ensure_prereqs` | `helper_unhealthy` | yes |
| 11 | `run_podman_command(login, debug)?` | `collect` | `operator_abandoned` / `empty_token` / `provider_reject` / `deadline` | **no**: all four become `Command exited with status N` or `Failed to run command: <timeout>` |
| 12 | `authentication verification failed after login` (`gh auth status`) | `verify_session` | `session_invalid` | yes |
| 13 | `in-container vault write failed` | `persist` | `vault_write` (covers `ca_bundle` inside the container, since `vault-cli.sh`'s `require_cacert` fails here) | partly: stage yes, reason is free-text stderr |
| 14 | `in-container vault write verification failed` | `verify_persisted` | `vault_readback` | yes |
| 15 | `vault feature not compiled` | `persist` | `no_vault_feature` | yes (build-time, not a runtime state) |
| 16 | `git identity was not saved` (since 1364-27f8, after persist) | `store_identity` (post-success, non-credential) | `identity_invalid` / `identity_write` | yes. The token is safe, so this belongs outside the credential FSM |
| — | `gh api user` (`podman_command_output(username_cmd` … `.ok()`) | `verify_persisted` (identity lookup) | none: the failure is swallowed | n/a: the success message just drops the username |

Rows 9 and 11 are the gaps criterion 2 asks about: fallible steps whose error
does not identify a reason. Row 11 matters most. The one exec that involves
the human carries four different outcomes in an exit status and nothing else.

### Second provider (Codex): three transitions in one exec

For every device-auth provider (`CODEX_DEVICE_AUTH_SPEC`,
`CLAUDE_DEVICE_AUTH_SPEC`, `ANTIGRAVITY_DEVICE_AUTH_SPEC`), rows 12–14 do not
exist on the Rust side. `collect`, `persist` and `verify_persisted` all run
inside the login script (`images/default/codex-device-auth.sh`,
`images/default/provider-device-auth.sh`), which is ONE
`run_podman_command(login)` exec. The Rust flow then re-runs
`verify_persisted` (row 14) on its own.

The script's exit code is the only reason channel:

| exit | meaning (script) | proposed `blocked{stage, reason}` |
|---|---|---|
| 2 | CLI lacks the device-auth capability / agy install failed / no agy login subcommand | `blocked{ensure_prereqs, provider_cli_unsupported}` (agy install failure: `provider_cli_install`) |
| 3 | login returned but wrote no credential file | `blocked{collect, no_credential_file}` |
| 64 | unknown provider argument | programming error, not a runtime state |
| other non-zero | `codex login` itself failed, OR `vault-cli.sh write-stdin` failed, OR `vault-cli.sh read` failed (`set -euo pipefail` passes the child's code through) | **ambiguous**: `collect` vs `persist` vs `verify_persisted` |
| deadline | 300 s budget (see above) | ambiguous with `abandoned` |

So for Codex, the "collected, not persisted" case, the incident this packet
exists for, cannot be told apart from "login failed" from the host side.
Two ways to fix it (decision left for the implementation packet):
(a) give the vault write and read-back their own exit codes in both scripts
(e.g. 4 = persist, 5 = verify_persisted), a small and local change;
(b) split the script so that, as with GitHub, `persist` is a separate exec
issued by the Rust flow, which gives one exec per transition and matches the
GitHub shape.
Option (a) is enough for the FSM's `blocked{stage}`. Option (b) is needed if
the FSM should be able to resume from `token_collected` without re-prompting
(the "resume vs re-prompt" decision). A device-code credential still sits in
the container only until the container's `--rm` cleanup.

### Side findings (recorded, not filed)

- `ProviderLoginConfig.auth_model` is never read, and the GitHub lane sets it
  to `AuthModel::OAuthDevice` although GitHub is a pasted-token flow
  (`AuthModel::Token`). It is a dead field with a wrong value. An FSM keyed on
  auth model must not trust it. Either delete it or make it correct when
  `LoginFlow<P>` lands.
- `ensure_provider_auth` (the agent-lane auto-login, `main.rs` ~16650) calls
  `run_provider_login` directly. It is nested inside the agent lanes, which
  844-aq78 already wraps in `run_cli_with_vault_credential_cleanup`, so it is
  covered. Noted so that a future refactor that lifts it out of that wrapper
  does not lose the drain.

## Completed Specifications & Evidence (Order 469 Closure)

### Criterion 1: FSM Specification for GitHub and Codex

#### 1. State Set
- `idle`: Rest state; no login in flight.
- `prereqs_pending`: Enclave runtime dependencies being ensured.
- `awaiting_operator`: Interactive prompt/browser open; credential not yet provided.
- `token_collected`: Credential acquired in ephemeral memory/container; not yet written to Vault.
- `token_persisted`: Credential written to Vault (`secret/<provider>/token`).
- `token_verified`: Credential read back and verified against provider API. (Terminal success)
- `blocked{stage, reason}`: Transition failure carrying failing stage and stable reason code. (Terminal failure)
- `abandoned`: Operator cancelled or timed out. (Terminal exit)

#### 2. Transition Set & Guards in Sibling-II Node Terms

| Provider | Transition | From | To | Guard Predicate (Sibling-II Nodes) |
|---|---|---|---|---|
| **GitHub** | `ensure_prereqs` | `idle` | `prereqs_pending` | `runtime:EnclaveNetwork` |
| | `prompt_open` | `prereqs_pending` | `awaiting_operator` | `runtime:Proxy` |
| | `collect_token` | `awaiting_operator` | `token_collected` | `input != ""` |
| | `persist_token` | `token_collected` | `token_persisted` | `runtime:Vault` ∧ `data:VaultReachable` ∧ `data:CaBundleValid` |
| | `verify_token` | `token_persisted` | `token_verified` | `runtime:Proxy` ∧ `data:EgressReachable` ∧ `data:VaultReachable` |
| | `store_identity` | `token_verified` | `token_verified` | `data:GitIdentityConfigured` |
| **Codex** | `ensure_prereqs` | `idle` | `prereqs_pending` | `runtime:EnclaveNetwork` ∧ `runtime:Proxy` |
| | `start_oauth` | `prereqs_pending` | `awaiting_operator` | `data:ProviderCliInstalled` ∧ `runtime:Proxy` |
| | `poll_oauth` | `awaiting_operator` | `token_collected` | `data:DeviceCodeApproved` ∧ `data:EgressReachable` |
| | `persist_token` | `token_collected` | `token_persisted` | `runtime:Vault` ∧ `data:VaultReachable` ∧ `data:CaBundleValid` |
| | `verify_token` | `token_persisted` | `token_verified` | `data:VaultReachable` |

### Criterion 3: Prototype `LoginFlow` Implementation & Verification
Implemented in `crates/tillandsias-control-wire/src/auth_flow.rs` and wired into `crates/tillandsias-control-wire/src/lib.rs`.
Unit tests executed and passing:
1. `test_collected_not_persisted_incident_lands_in_blocked_persist_not_idle`: Proves that a CA bundle / Vault failure during persist preserves the `TokenCollected` stage failure as `LoginState::Blocked { stage: LoginStage::Persist, reason: BlockedReason::CaBundle }`, and explicitly does NOT regress silently to `Idle` or `LoggedOut`.
2. `test_is_possible_persist_returns_blocked_ca_bundle_when_ca_unsatisfied`: Proves that guard evaluation checks dependency prerequisites and returns `GuardVerdict::Blocked(BlockedReason::CaBundle)` when CA bundle is missing.
3. `test_full_happy_path_reaches_token_verified`: Proves the full transition sequence from `Idle` through `TokenVerified`.

### Criterion 4: Decision Record
1. **Crate Location**: `crates/tillandsias-control-wire/src/auth_flow.rs`. Lives in `tillandsias-control-wire` so that guest (`tillandsias-headless`), host daemon (`tillandsias-host-shell`), and all three GUI trays (`tillandsias-*-tray`) share the exact same serialized state machine and reason vocabulary without duplication or protocol drift.
2. **Reason Vocabulary**: Extends stable dot-separated error taxonomy (`auth.<provider>.err.<reason>`), using strongly-typed Rust enum `BlockedReason` on the wire and serializable for events.
3. **Guard Evaluation Strategy**: Evaluated lazily on transition attempt via `is_possible(stage, prereqs) -> GuardVerdict`. A lazy check avoids redundant continuous polling across all providers while ensuring zero unverified transitions.
4. **Resume vs Re-prompt**: For pasted-token flows (GitHub), resumption from `token_collected` is possible as long as the memory buffer survives within the session; for device-auth flows (Codex/Claude), container recreation forces a re-prompt/re-authentication if the script process exits before persist.

### Criterion 5: User-Visible States vs Internal States
- **User-Visible States (Driving the Tray Chip)**:
  - `Idle` → "Logged Out"
  - `PrereqsPending` → "Preparing Enclave..."
  - `AwaitingOperator` → "Awaiting Input..."
  - `TokenCollected` → "Saving Credentials..."
  - `TokenPersisted` → "Verifying Token..."
  - `TokenVerified` → "Logged In"
  - `Blocked { .. }` → "Login Failed" (tooltip displays exact stage and reason)
  - `Abandoned` → "Login Cancelled"
- **Internal-Only**: Discrete guard evaluations (`GuardVerdict::Possible` / `GuardVerdict::Blocked`), raw token buffers, and post-verification identity synchronization details (`StoreIdentity`).

