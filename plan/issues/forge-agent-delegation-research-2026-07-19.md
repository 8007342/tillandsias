# Forge agent delegation — OpenCode + Codex prompt dispatch, vault-isolated (2026-07-19)

- **Status**: research COMPLETE — implementation packets below are ready, RESEARCH GATE SATISFIED
- **Owner host**: linux
- **Branch**: linux-next
- **Specs**: tillandsias-vault, forge-offline, forge-hot-cold-split,
  zen-default-with-ollama-analysis-pool
- **Goal (operator, 2026-07-19)**: the tillandsias-linux headless agent sends PROMPTS
  to OpenCode and Codex running headless in forge containers, each with its own
  in-RAM checkout, working concurrently. First step toward ZeroClaw agent-to-agent
  message passing. Credentials must live in the vault container, "outside of agents'
  curious hands."

## Headline

**Both tools can run with ZERO on-disk credential state, fed entirely from the vault
at launch.** Both expose an env-var path that short-circuits credential-file reads
before any disk access. Both were verified empirically against the installed binaries
(opencode 1.18.3, codex-cli 0.144.4).

**The vault container already exists and is mature** — Vault 1.18 pinned, AppRole
per-container tokens, Shamir auto-unseal, 11 least-privilege policies, SELinux module,
RAII `AppRoleSecretLease` that revokes on drop, secrets moved container→Vault→container
over **stdin only** (never argv, never env). The gap is not the vault. OpenCode was
never wired to it, and the Codex wiring is broken.

## Credential injection — verified recipes

```bash
# OpenCode worker N
XDG_DATA_HOME=/ram/w$N XDG_STATE_HOME=/ram/w$N XDG_CONFIG_HOME=/ram/w$N \
OPENCODE_AUTH_CONTENT="$(vault read …)" \
OPENCODE_DB=:memory: \
opencode run --format json "$PROMPT"

# Codex worker N
CODEX_HOME=/ram/w$N CODEX_API_KEY="$(vault read …)" \
codex exec --ephemeral --json --skip-git-repo-check "$PROMPT"
```

### OpenCode

- Credentials live at `$XDG_DATA_HOME/opencode/auth.json`, mode 0600, **plaintext**.
- **`OPENCODE_AUTH_CONTENT`** is the vault primitive: `Auth.all()` parses it and
  returns immediately, never touching `auth.json`. Verified end-to-end — `opencode
  auth list` reported 2 credentials with **no `auth.json` on disk**.
  - Caveat: **undocumented, source-only**. A dependent lane must either pin the
    OpenCode version or positively assert the parse/no-file contract on every
    selected binary. Order 431 chose the positive assertion. Malformed JSON
    fails silently back to the file path (bare `catch {}`), so assertion
    failure is fatal.
  - Ordering gotcha: `auth.json` merges *after* env, so stored credentials override
    env vars. Vault injection must therefore also guarantee no stale `auth.json`.
- Upstream moved: `github.com/sst/opencode` now redirects to `github.com/anomalyco/opencode`.
- Headless: `opencode run "prompt" --format json` emits JSONL (`step_start`, `text`,
  `step_finish`), each carrying `sessionID`. Server mode: `opencode serve`, with
  `POST /session`, `POST /session/:id/message`, SSE at `/global/event`, OpenAPI at
  `/doc`, SDK `@opencode-ai/sdk`.
- Zero-auth is real and is why our lane runs unauthenticated today: config-declared
  providers merge with `source:"config"` and never consult auth at all.
- **Concurrency hazard**: `auth.json` is NOT lock-protected (a `Flock` utility exists
  but covers only plugin/theme/MCP-auth). Concurrent OAuth refreshes across instances
  can lose updates. Per-worker `XDG_*` is mandatory.

### Codex

Four assumptions we held were outdated. Most importantly:

- **`OPENAI_API_KEY` does NOT authenticate Codex.** Proven with bogus-key runs against
  an empty `CODEX_HOME`:

  | Env var | Error | Meaning |
  | --- | --- | --- |
  | `OPENAI_API_KEY` | `Missing bearer or basic authentication in header` | key **ignored** |
  | `CODEX_API_KEY` | `Incorrect API key provided: sk-bogus*****-111` | key **used** |

- `CODEX_API_KEY` short-circuits in `load_auth` with no disk write — no `auth.json`
  was created in either run. **Gated to `codex exec` only**; explicitly disabled in
  the TUI.
- Also outdated: `preferred_auth_method` → `forced_login_method`; `--api-key` removed
  in favour of `--with-api-key` reading **stdin**; `wire_api="chat"` gone (`responses`
  only).
- `cli_auth_credentials_store` supports `file | keyring | auto | ephemeral`
  (in-memory).
- Headless: `codex exec "prompt" --json` → JSONL (`thread.started`, `turn.*`,
  `item.*`, `error`), plus `-o/--output-last-message FILE` and `--output-schema`.
  `--ephemeral` eliminates the `sessions/` directory entirely (confirmed).
- **Concurrency hazard, worse than OpenCode**: `auth.json` writes are
  truncate-then-write with **no advisory lock**. Upstream #11435 (parallel `codex exec`
  cross-talk) and #20213 (SQLite deadlock, no `SQLITE_BUSY` retry). One `CODEX_HOME`
  per worker is **mandatory**.

Nothing forces *credential* state to disk for either tool. What forces disk state is
non-credential state (SQLite, sessions) — solved by putting the data dirs on tmpfs so
they die with the container.

## Bugs found in-repo

### Bug 1 — Codex lane gets the wrong env var AND skips its vault restore (high)

`vault_bootstrap.rs` maps `ProviderId::Openai → "OPENAI_API_KEY"` and `main.rs`
injects it into the Codex lane. Codex **ignores** that variable. Worse,
`images/default/entrypoint-forge-codex.sh` does:

```bash
if [ -z "${OPENAI_API_KEY:-}" ]; then
    /usr/local/bin/codex-oauth-vault restore
fi
```

So injecting `OPENAI_API_KEY` **suppresses the vault OAuth restore** *and* supplies no
working credential — the lane ends up with no auth at all. Fix: emit `CODEX_API_KEY`
and gate the restore on that.

### Bug 2 — dead flag (low)

`entrypoint-forge-opencode.sh` passes `--dangerously-skip-permissions`. That flag does
not exist in opencode 1.18.3 (zero occurrences in the binary); opencode silently
ignores unknown flags (yargs non-strict) so it is not breaking. Permissions actually
come from `"permission": "allow"` in the config overlay. The modern flag is `--auto`.

### Bug 3 — spec drift, never proposed (medium)

`openspec/specs/tillandsias-vault/spec.md` R6 states "Forge containers receive zero
Vault tokens" and cannot reach `vault:8200`. The implementation has deliberately done
the opposite since 2026-07-14. The narrowing is genuine and safe, but **no change
proposal was ever filed** — two invariants are false as written.

## Structural blockers for concurrent delegation

| # | Gap | Severity |
| --- | --- | --- |
| 1 | **Container names collide by construction.** `tillandsias-{project}-forge-{mode}` has no instance component, and `--replace` means worker 2 **destroys** worker 1. | BLOCKER |
| 2 | **No per-worker in-RAM checkout.** `forge-hot-cold-split/spec.md` requires `/home/forge/src` be tmpfs; it is a read-write bind mount of the host checkout. Sizing helpers (`compute_hot_budget`, `check_host_ram`, `compute_memory_ceiling_mb`) exist and are unit-tested but have **zero production callers**; `--memory` is never passed. Already caused near-data-loss (`forge-shared-checkout-destructive-clean-2026-07-13.md`). | BLOCKER |
| 3 | No result-retrieval path — prompting is fire-and-forget; no `--format json` / `--json` output is consumed anywhere. | BLOCKER |
| 4 | Per-worker `XDG_*` / `CODEX_HOME` isolation absent (mandatory per upstream races). | HIGH |
| 5 | OpenCode has no vault provider — no `OPENCODE_AUTH_CONTENT` path exists. | HIGH |
| 6 | Prompt delivery is launch-time only: `--env TILLANDSIAS_{OPENCODE,CODEX}_PROMPT` at `podman run`. **No channel to a running container.** Non-interactive prompting hard-errors as Codex-only, so Claude/Antigravity cannot be prompted. | HIGH |
| 7 | Open P1: vault unseal-secret regeneration crash-loop can brick a healthy vault on restart (`vault-unseal-secret-regenerated-on-reensure-2026-07-17.md`). | HIGH |

**ZeroClaw does not exist** — it was deleted as a critical violation and is gated
behind an unstarted milestone. The forge→host MCP socket exposes only
`publish_local`, `service_status`, `service_stop`.

Gaps 1 and 2 together are the structural blocker: **two workers on one project cannot
coexist safely today.** Gaps 4/5 and Bug 1 are the credential-isolation work, and all
are small — the vault, the lease machinery, and the injection point already exist.

## Recommended implementation ladder

Each rung is independently landable and independently verifiable. Rungs 1-3 are
prerequisites for any concurrency at all.

1. **Instance-scoped container names** — add a worker/instance component to the
   container name; stop `--replace` from destroying siblings. Litmus: two workers on
   one project coexist.
2. **Per-worker state isolation** — tmpfs `/home/forge/src`, per-worker `XDG_*` and
   `CODEX_HOME`, wire the existing-but-uncalled memory-ceiling helpers. Litmus:
   concurrent workers produce no cross-talk; host checkout is never mutated.
3. **Structured result retrieval** — consume `opencode run --format json` /
   `codex exec --json` JSONL, surface per-worker outcome to the dispatcher. Litmus:
   dispatcher distinguishes success / failure / timeout per worker.
4. **Fix Bug 1** — emit `CODEX_API_KEY`, gate the vault restore on it. Litmus: Codex
   lane authenticates with no `auth.json` on disk.
5. **OpenCode vault provider** — **implemented 2026-07-23 (order 431)**.
   The launcher mounts an `opencode-forge` AppRole token, and the entrypoint
   derives `OPENCODE_AUTH_CONTENT` from the existing Gemini source. The
   selected installed binary must report the provider/count with no
   `auth.json`; contract failure restores the persistent last-good binary.
6. **Runtime prompt channel** — a way to prompt an already-running container, and
   lift the Codex-only restriction. This is the ZeroClaw precursor.
7. **File the vault spec-drift change proposal** (Bug 3).

## Sources

External behaviour above was verified empirically against installed binaries
(opencode 1.18.3, codex-cli 0.144.4) rather than taken from documentation, because
several documented claims were found stale. Upstream issue references:
codex #11435 (parallel `exec` cross-talk), #20213 (SQLite deadlock).

## Order 431 implementation evidence — 2026-07-23

The implementation preserves `secret/gemini/api-key` as the only credential
producer. A new read-only `opencode-forge-policy` can read exactly
`secret/data/gemini/api-key`; it has no metadata, list, write, OAuth, GitHub,
OpenAI, or Anthropic access. The launcher checks presence without capturing the
key, mounts only the short-lived AppRole token, and never puts the key or
derived document in Podman argv.

Inside the forge, the entrypoint removes any real file or symlink at
`$XDG_DATA_HOME/opencode/auth.json`, reads the key through `vault-cli.sh`, and
builds the `google` API auth record through `jq -Rsc` stdin. It then runs the
selected OpenCode binary's `auth list` against isolated XDG state and requires
the expected provider and credential count with no auth file. The
every-launch official curl refresh is retained: a candidate that violates the
undocumented env/no-file contract takes the same persistent last-good rollback
as a liveness failure. With no Gemini key, the launcher mints no provider token
and the free Zen/local lane remains credential-free.

Evidence on this forge:

- locally installed OpenCode 1.18.4 reported provider `google`, count 1, with
  `auth.json` absent using a runtime-generated sentinel;
- `scripts/test-opencode-vault-auth-content.sh` passed the free lane,
  Vault-adapter, installed-binary, no-file, no-persistence, and rollback cases;
- the focused Vault policy and headless Podman-argv unit tests passed;
- `litmus:opencode-vault-auth-content` binds the canonical default-image,
  tillandsias-vault, podman-secrets-integration, and
  security-privacy-isolation contracts.
- after rebasing onto `origin/linux-next` at 148a9076, `./build.sh --check`,
  all 16 `opencode_`-filtered headless tests, all six Vault policy tests,
  both existing harness contract/rollback fixtures, and touched-YAML
  validation passed.

This host has no Podman binary, so no live Vault/container credential was used.
That is not an unverified exit criterion: the producer/path and mount shapes
are covered hermetically, while the undocumented OpenCode consumer contract is
proved against the locally installed 1.18.4 binary without a committed or live
credential.

## Order 429 current-run result repair — 2026-07-24

The earlier consumption claim was structurally false: launch builders did not
propagate JSON mode, attached stdout was inherited rather than captured,
OpenCode had no host consumer, a caller-selected result path could contribute
stale evidence, nonzero status was discarded, and timeout cancellation could
orphan the worker. The repaired source path now:

- opts only nonblank prompted JSON runs into fresh bounded stdout capture for
  OpenCode CLI and Codex while preserving the inherited TUI path and omitting
  the unsupported request from detached OpenCode Web serve;
- parses the current nested CLI schemas, keeps failure sticky, and treats the
  real nonzero/signal process status as authoritative;
- invalidates and atomically replaces any optional host result file without
  ever reading it as evidence;
- retains at most 16 MiB while draining stdout, and makes overflow ineligible
  for success; and
- requires an exact instance-scoped worker identity, then performs bounded
  checked exact-name removal, reap, Podman-CLI kill-on-drop backstop, and a
  second exact removal at timeout without listing or touching siblings.

Deterministic no-Podman evidence covers both CLI builders, Web omission, the
exact Codex `--json` entrypoint command seam, actual Codex/OpenCode event
shapes, stale preseed rejection, production-wrapper rejection of a
success-looking exit 37, and exact timeout cleanup with sibling survival. The
selected headless tests pass 11/11 and the bounded-capture helper passes 1/1.

Order 429 remains in progress. Closure still requires a built forge with real
Podman to run genuinely failed delegated Codex and OpenCode tasks and prove the
delegating process reports failure end to end while an adjacent scoped worker
survives.
