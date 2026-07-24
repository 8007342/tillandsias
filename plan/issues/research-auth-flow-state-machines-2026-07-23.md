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
