# RESEARCH: harness init/launch waiting-state — per-harness inventory of silent-vs-signalled long work, and the pre-banner "setting up …" surface that closes the Codex-silent-start gap (2026-07-23)

- **Class**: research (MANDATORY before implementation, operator standing rule)
- **Status**: proposed
- **Desired release**: future (v0.5+) — NOT blocking current v0.4/v0.3 work; durable
  direction. The pre-banner "setting up <harness>…" line is the smallest slice that
  directly fixes the operator's named symptom (Codex looks hung on cold start).
- **Owner host**: any (the entrypoints run inside the forge; the surface is the forge
  popup terminal on all three hosts, plus an optional tray "Preparing your forge…" chip)
- **Operator vision (2026-07-23, The Tlatoāni, paraphrased — preserve intent)**: Codex
  "always takes some time to start" — likely a Node.js first-run bootstrap/install
  through the enclave proxy plus a remote model/config handshake — and it does so with
  no "this is normal, please wait" indication, so it reads as hung. If ANY harness does
  slow work at init/launch we MUST show the user that this is a NORMAL, VALID WAITING
  STATE. Users must never be left wondering whether the system is hung.
- **Motivating incident**: the confirmed mechanism below — `require_codex` runs a
  FOREGROUND `npm install @openai/codex@latest` whose only status is a DEBUG-GATED trace,
  so a non-debug user's forge terminal is blank for the whole cold install, before the
  welcome banner even prints.
- **Parent contract**: `plan/issues/research-valid-waiting-state-contract-2026-07-23.md`
  (this lane supplies the harness-init half of that contract's known-long-operation
  registry and the harness-specific surface).
- **Sibling lane**: `plan/issues/research-forge-bringup-waiting-state-2026-07-23.md`
  (image build / VM boot / git-mirror seed / inference — the other long-op cluster).
- **Cross-references**: `plan/issues/research-flow-state-event-channel-2026-07-23.md`
  (a harness-install `→ installing → ready` transition is emitted, not polled);
  `plan/issues/stable-state-codes-research-2026-07-05.md` (the `init.harness.*` codes);
  `plan/issues/forge-firstrun-tool-migration-2026-07-04.md` (order 180) and
  `plan/issues/forge-harness-every-launch-latest-2026-07-04.md` (order 181) — the
  history of what was deliberately moved to FIRST_RUN / EVERY_LAUNCH and thus became a
  launch-time wait.

## Motivation

The operator's repro is precise: Codex starts slowly with no "please wait" indication.
Tracing the actual launch path confirms the mechanism and shows it is shared by every
harness, not just Codex.

`entrypoint-forge-codex.sh` runs, in order: `populate_hot_paths` (`:65`) →
`ensure_forge_prebuilt_tools &` + `ensure_forge_harnesses &` (`:70-71`, backgrounded) →
`clone_project_from_mirror` (`:79`, foreground) → `require_codex` (`:99`, foreground) →
`codex-oauth-vault restore` (`:112`, foreground) → `show_banner "codex"` (`:116`) →
`exec codex` (`:168`). The two operations that block the visible launch — the mirror
clone and `require_codex` — both run BEFORE the banner, and both are silent to a normal
user:

- `require_codex` → `_require_harness codex "@openai/codex" codex`. On a cold cache it
  runs `npm install -g --no-audit --no-fund "@openai/codex@latest" >"$errlog" 2>&1`
  (`lib-common.sh:1528`) — a full Node.js first-run install through the enclave proxy,
  with stdout/stderr redirected to a temp file. The only status is
  `trace_lifecycle "harness" "$name missing — install latest"` (`:1526`), and
  `trace_lifecycle` no-ops unless `TILLANDSIAS_DEBUG` is set (`:198`). If a sibling
  container is mid-update, `_require_harness` can additionally block up to 90 s waiting
  on the npm-update lock (`:1516`) — also silent.
- The banner (`show_banner`, `lib-common.sh:2817`) is a "you are ready" signal that only
  prints AFTER these waits — so during the slow part the terminal shows nothing.

This is the class the operator named. It is NOT unique to Codex: Claude and OpenCode
route through `curl_install_claude` / `curl_install_opencode`, where a cold refresh can
block up to **900 s** behind a refresh lock (`lib-common.sh:1884` default `wait_limit=900`,
wait loop `:1953-1956`), equally silent; Antigravity's `require_antigravity` retries the
installer 3× and DOES print an actionable FAILURE banner (`entrypoint-forge-antigravity.sh:90-105`)
but shows no WAITING signal while the installs are in flight. The backgrounded
`ensure_forge_prebuilt_tools` / `ensure_forge_harnesses` do not block the banner, but they
can hold per-tool locks for up to 420 s (`install_prebuilt`, `lib-common.sh:853`) and a
subsequent foreground `require_*` can then wait on them — again with no user-visible
signal.

## Proposed model

Give the forge popup terminal a **pre-banner valid-waiting-state line** for any harness
init step that will block launch beyond T_visible, and (optionally) a tray "Preparing
your forge…" chip so the wait is visible on the menu too. Concretely, per the parent
contract: emit on ENTRY to the wait, non-debug, with what / expected / rough-duration.

**The surface (draft wording — verbatim strings fixed in the entrypoint/lib, mirroring
the condensed-status precedent):**

- Foreground harness install, cold cache:
  `⏳ Setting up the <Harness> toolchain… (first launch — this is normal; ~30–90 s)`
  printed once, before the blocking `require_<harness>` call, on stderr of the forge
  terminal (before any TUI claims the display).
- Foreground install waiting on a sibling updater lock:
  `⏳ Finishing a shared toolchain update… (this is normal; up to ~90 s)`.
- On success, advance to the existing banner (the banner remains the ready signal).
- On failure, the existing classified failure banners (`harness_missing_fatal`,
  Antigravity's egress-allowlist message) already carry the actionable verdict — the
  waiting line simply resolves into them.

**Why a deliberate single line, not un-muting the installer.** The forge lane mutes
subprocess stdout precisely because npm's "added N packages" lands mid-frame and corrupts
a live TUI (`lib-common.sh:1356-1360`, operator repro 2026-07-12 escape-char spill). So
the fix is NOT to show raw npm output; it is one intentional pre-banner print on entry,
plus (behind `--debug`) the existing detailed traces for developers.

**Stable code + emit-not-poll.** Each harness-init wait gets a dotted code
(`init.harness.codex.installing`, `.opencode.refreshing`, `.prebuilt-tools.fetching`,
reusing `stable-state-codes-research-2026-07-05.md`) so the same state can drive the
terminal line, an optional tray chip via `FlowStatePush` (sibling event-channel), and a
`--diagnose` entry — from one emission on entry/exit, never a poll.

### Per-harness / per-step inventory (classification: SILENT vs EMITS)

| Step | Where | Blocks banner? | Bound | Today | Class |
|---|---|---|---|---|---|
| `require_codex` cold npm install | `entrypoint-forge-codex.sh:99` → `lib-common.sh:1528` | yes | ~unbounded (npm) | debug-only trace; npm → tempfile | **SILENT** |
| `require_claude` curl refresh | `entrypoint-forge-claude.sh:70` → `curl_install_claude` `lib-common.sh:1879` | yes | up to 900 s lock wait (`:1953`) | debug-only traces | **SILENT** |
| `require_opencode` curl refresh | `entrypoint-forge-opencode.sh:71` → `curl_install_opencode` `lib-common.sh:1625` | yes | lock wait | debug-only traces | **SILENT** |
| `require_antigravity` (3× installer) | `entrypoint-forge-antigravity.sh:90` | yes | 3 attempts | FAILURE banner only (`:92-104`); no WAIT signal | **SILENT (wait) / EMITS (failure)** |
| `require_openspec` npm install | claude/opencode entrypoints → `lib-common.sh:2000` | yes | npm | debug-only trace | **SILENT** |
| sibling npm-update lock wait (≤90 s) | `_require_harness` `lib-common.sh:1516` | yes | 90 s | debug-only trace | **SILENT** |
| `ensure_forge_prebuilt_tools` (FIRST_RUN) | entrypoints `… &`; `lib-common.sh:953` | no (bg) | per-tool lock ≤420 s (`:853`) | debug-only traces | **SILENT (non-blocking)** |
| `ensure_forge_harnesses` (EVERY_LAUNCH) | entrypoints `… &`; `lib-common.sh:1294` | no (bg) | minutes | debug-only; stdout muted (`:1360`) | **SILENT (non-blocking)** |
| Codex OAuth restore + remote handshake | `entrypoint-forge-codex.sh:112` `codex-oauth-vault restore` | yes | seconds | debug-only | **SILENT (short)** |
| `show_banner` | `lib-common.sh:2817` | — | — | prints AFTER waits | **READY signal, not a wait** |

Every blocking harness-init step is currently SILENT to a non-debug user. Only failure
paths (Antigravity, `harness_missing_fatal`) speak — and only after the wait is over.

## Investigate / prototype

- **Which steps exceed T_visible in practice.** Measure cold-cache durations for each
  row (first-run codex npm install, claude/opencode curl refresh, openspec install,
  prebuilt-tools fetch) on a representative slow-link enclave proxy. Only genuinely-long
  steps get a line; short ones (OAuth restore) likely do not.
- **Exact print site + ordering.** The line must precede the blocking `require_*` call
  and land before any TUI. Prototype the placement in each entrypoint relative to
  `clone_project_from_mirror`, `require_*`, and `show_banner`; confirm it does not
  interleave with the banner or with a `codex exec`/`opencode run` non-interactive launch.
- **Cold vs warm detection.** The line should only appear when work will actually happen
  (cache miss / lock held), not on a warm launch that no-ops in milliseconds. Reuse the
  existing "is current / cached" fast-paths (`claude_refresh_is_current` `:1899`;
  `install_prebuilt` executable fast-path `:835`) to gate the print.
- **Duration estimates.** Can a rough estimate be derived (e.g. record last cold-install
  wall time in the persistent cache and show "~last time it took Ns")? Or is a static
  bucket ("first launch, up to ~2 min") sufficient? Coarse is acceptable per the operator.
- **Tray chip parity (optional).** Should the forge popup's waiting also raise a tray
  "Preparing your forge…" chip (parity with `CONNECTING_CHIP_TEXT`,
  `action_host.rs:790`)? This needs the launch→tray signal path (sibling event-channel).
- **Antigravity wait line.** `require_antigravity` already owns the failure UX; add the
  matching WAIT line on entry so the 3-attempt install window is not silent.
- **Backgrounded steps.** `ensure_forge_prebuilt_tools` / `ensure_forge_harnesses` do not
  block the banner, so they need NO waiting line by themselves — but a later foreground
  `require_*` that BLOCKS on their lock does. Confirm the waiting line attaches to the
  blocking foreground wait, not the harmless background task.
- **Non-interactive lanes.** For `codex exec` / `opencode run --auto` (e2e / unattended,
  `entrypoint-forge-codex.sh:149`, `entrypoint-forge-opencode.sh:187`) there is no human
  watching a terminal — the waiting line is harmless but the tray/diagnostics code is the
  relevant surface. Confirm the machine-readable JSON result path is unaffected.

## Exit criteria

- A **complete, verified per-harness inventory** (the table above, checked against source
  with file:line) classifying every init/launch step as SILENT vs EMITS and blocking vs
  background — the harness-init rows of the parent contract's known-long-operation
  registry.
- A **surface design**: the verbatim pre-banner waiting-line strings per harness, their
  exact print site, the cold-vs-warm gate that suppresses them on a no-op warm launch,
  and the duration-estimate approach (static bucket vs recorded last-time).
- A **prototype** (behind a flag or scratch entrypoint) that, on a cold harness cache with
  `--debug` OFF, prints the "Setting up the Codex toolchain… (first launch; ~Ns)" line
  before `require_codex` blocks — demonstrably closing the named symptom — and prints
  nothing on a warm launch.
- A **falsification test**: the parent guardrail's runtime litmus goes RED if the waiting
  line is removed or re-gated behind `--debug`, using a forge lane with a pre-emptied
  harness cache.
- A decision record: which steps qualify (> T_visible), the wording, the estimate source,
  and whether a tray chip mirrors the terminal line.

## Existing-code references

- `images/default/entrypoint-forge-codex.sh:99,112,116,168` — `require_codex` (silent
  blocking wait), OAuth restore, `show_banner` (ready-not-wait), `exec codex`.
- `images/default/entrypoint-forge-claude.sh:70,118,139` — `require_claude`,
  `show_banner`, `exec claude`.
- `images/default/entrypoint-forge-opencode.sh:71,94-100,135` — `require_opencode`,
  inference probe (debug-only trace), `show_banner`.
- `images/default/entrypoint-forge-antigravity.sh:90-105` — `require_antigravity`: FAILURE
  banner exists, WAIT signal does not.
- `images/default/lib-common.sh:198` — `trace_lifecycle` is DEBUG-ONLY (the whole trace
  channel is invisible to a normal user).
- `images/default/lib-common.sh:1501-1544` — `_require_harness`: `:1516` sibling-lock wait
  (≤90 s, silent); `:1526` debug-only "missing — install latest"; `:1528` foreground
  `npm install … >"$errlog" 2>&1` (Codex cold-start wait, output to tempfile).
- `images/default/lib-common.sh:1879-1980` — `curl_install_claude`: `:1884` `wait_limit`
  default 900; `:1953-1956` bounded silent wait behind the refresh lock.
- `images/default/lib-common.sh:1625` — `curl_install_opencode` (parallel silent refresh).
- `images/default/lib-common.sh:832-860,835,853` — `install_prebuilt`: executable
  fast-path (`:835`) and per-tool lock wait up to ~420 s (`:853`).
- `images/default/lib-common.sh:945-1024,953` — `ensure_forge_prebuilt_tools` (FIRST_RUN,
  backgrounded, debug-only traces).
- `images/default/lib-common.sh:1287-1360,1356-1360` — `ensure_forge_harnesses`
  (EVERY_LAUNCH, backgrounded, stdout MUTED to protect the TUI — why raw output can't be
  the surface).
- `images/default/lib-common.sh:2817-2830` — `show_banner`: the ready signal that prints
  after the waits.
- `crates/tillandsias-macos-tray/src/action_host.rs:790` — `CONNECTING_CHIP_TEXT`:
  precedent for a waiting chip if the tray mirrors the terminal line.
- `plan/issues/forge-firstrun-tool-migration-2026-07-04.md` (order 180) /
  `plan/issues/forge-harness-every-launch-latest-2026-07-04.md` (order 181) — why these
  became launch-time waits.

## Non-goals / scope

- NOT the universal contract or the guardrail mechanism — that is the parent packet; this
  lane supplies its harness rows and surface.
- NOT the forge-stack (image/VM/mirror/inference) long ops — sibling lane packet.
- NOT un-muting npm/curl subprocess output (it corrupts the TUI); the surface is one
  deliberate pre-banner line plus the existing `--debug` traces.
- NOT changing what gets installed, the install ordering, the rollback/last-good logic
  (order 284), or the credential/Vault restore — this only surfaces the wait around them.
- NOT the classified FAILURE banners (they already exist and are correct) — the waiting
  line resolves INTO them on failure.
- NOT a v0.4 change; durable v0.5+ direction. Do NOT modify code under this packet.
- NOT ZeroClaw / agent↔agent messaging (deleted as a critical violation; out of scope).
