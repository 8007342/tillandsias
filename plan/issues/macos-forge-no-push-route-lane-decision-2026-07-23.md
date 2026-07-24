# P1 BLOCKER + DECISION: macOS forge has no git push route (agent work cannot persist)

- **Date:** 2026-07-23
- **Class:** blocker + decision
- **Area:** forge source-routing (SRC-ISOLATION lane) / git-mirror push relay
- **Severity:** P1 — agents in the macOS forge can COMMIT but not PUSH; work is stranded in the ephemeral `--rm` container overlay and lost on relaunch. The forge's purpose is agents doing work that PERSISTS via push; the macOS forge currently cannot persist any agent work.
- **Owner:** Linux/forge to implement; macOS-observed. **OPERATOR (Tlatoāni) must choose the lane/approach (see Decision below).**
- **Discovered by:** operator report across a live attended macOS forge session — **three different harnesses fail identically**: BigPickle, Codex, and Claude each commit fine but `git push` fails.

## Symptom (proven NOT credentials, NOT harness-specific)

Every harness run in the macOS forge commits cleanly but its `git push` fails; the commits sit only in the `--rm` container overlay. Three harnesses (BigPickle meta-orchestration, Codex orchestration, Claude) fail identically → it is the **lane**, not credentials and not a harness quirk.

## Root cause: the macOS SRC-ISOLATION lane wires no push route

- macOS launches the forge in SRC-ISOLATION (clone) mode: `crates/tillandsias-macos-tray/src/diagnose.rs:1191-1226` sets `TILLANDSIAS_FORGE_SRC_ISOLATION=clone`.
- `crates/tillandsias-headless/src/main.rs:4753-4766` bind-mounts the operator checkout **read-only** at `src-host` and sets `TILLANDSIAS_GIT_MIRROR_PATH`; the entrypoint then clones a FRESH working tree from that read-only staged path into the container overlay.
- That lane sets `TILLANDSIAS_GIT_MIRROR_PATH` but **never `TILLANDSIAS_GIT_SERVICE`** (`main.rs:4753-4795`), so no enclave push route is installed: origin is the bare GitHub URL (unreachable from the offline enclave), the staged "mirror" is read-only + `denyCurrentBranch`, and there is no `git://` mirror push. `images/default/lib-common.sh:553-572` traces exactly this — "no push route (non-bare staged source)" (the `macos-clone-lane-push-remote-misalignment` class).

## Why the OTHER platforms push fine today (the comparison)

All three run a Linux forge; the difference is the per-platform source + push LANE:

| Platform | Network | Push route today |
| --- | --- | --- |
| **Linux native** (mutable host) | NOT enclave-isolated — it *is* the host | Pushes **directly to GitHub** with the host's own git credentials. No mirror needed. |
| **Windows / WSL2** (enclave VM — macOS's true twin) | Enclave-isolated | Pushes through the **internal `git://` mirror** (`TILLANDSIAS_GIT_SERVICE` → `tillandsias-git`), which relays to GitHub via `images/git/relay-refs.sh` → `git-credential-tillandsias.sh` → the Vault token. A wired, working push route. |
| **macOS** (enclave VZ VM) | Enclave-isolated | **SRC-ISOLATION clone lane — no push route.** Same enclave situation as Windows, solved a different way (order 342: read-only virtiofs staged mount + clone, deliberately "no host-mount, no gitdir facade" to fit the VZ/virtiofs model), and that lane never wired the `git://` mirror push that Windows has. |

**So macOS is the odd one out for an architectural reason, not because pushing is hard:** it is the same enclave-VM problem as Windows/WSL2, but macOS took the SRC-ISOLATION path and skipped the push half.

> TO CONFIRM (the investigating agent confirmed these but died before writing them here): the exact Windows/WSL2 launch path that sets `TILLANDSIAS_GIT_SERVICE` (`scripts/install-windows.ps1` / the WSL launch + the windows source-routing branch in `main.rs`), and the Linux-native direct-push path. The mechanism above is confirmed; the Windows file:line should be pinned when Option B is implemented.

## Fix options

### OPTION B — wire the `git://` mirror push into the macOS SRC-ISOLATION lane  *(RECOMMENDED)*
Make the macOS enclave forge push the **same way Windows/WSL2 already does**: set `TILLANDSIAS_GIT_SERVICE` and wire the mirror push + relay for the macOS lane (`main.rs:4753-4795`), so agent commits push to `tillandsias-git`, which relays to GitHub via the Vault token (`relay-refs.sh`, `git-credential-tillandsias.sh`).
- **Pros:** keeps the read-only clone isolation macOS deliberately chose; it is **parity with a proven mechanism** (not a novel design); reuses the existing mirror + relay + Vault credential path.
- **Cons:** real wiring work (the relay/receive-pack path must be reachable from the macOS lane); must confirm the mirror-readiness gate (see `mirror-readiness-gate-seeded-not-reachable-2026-07-23.md`).

### OPTION A — switch the macOS forge to the HOST-MOUNT lane
`TILLANDSIAS_FORGE_HOST_MOUNT=1` bind-mounts the operator checkout rw and installs the enclave push redirect via `rewrite_origin_for_enclave_push` (`lib-common.sh:440-457, 483-503`; forge-args branch `main.rs:4767-4781`) — likely a launcher-flag flip on the macOS side.
- **Pros:** quickest to enable; push works via the enclave redirect.
- **Cons:** **loses the read-only clone isolation** macOS deliberately chose; installs the gitdir facade; agent edits become visible on the host without a commit. Trades away the property SRC-ISOLATION exists to provide.

### OPTION C — `git bundle` export to the virtiofs `~/src` share
A workaround, not a fix: bundle the overlay checkout to the host-visible `~/src`. Preserves nothing about the normal push workflow; only useful for one-off recovery.

## OPERATOR DECISION POINT

**Choose the lane:** **Option B (recommended)** — give the macOS forge the same `git://` mirror push route Windows/WSL2 already use (parity, keeps isolation) — vs **Option A** (host-mount, faster but drops the isolation). Option C is recovery-only.

## Recovery of currently-stranded commits (while a forge is live)

Per the recovery trace: `tillandsias-tray --exec-guest 'podman cp <forge-container>:/home/forge/src/<project> /home/forge/src/<name>-recovery'` lifts the overlay checkout onto the virtiofs `~/src` (= the Mac's `~/src`) WITHOUT running the wiping entrypoint (`podman cp` does not exec). Then push from the Mac normally. Recoverable only while the `--rm` forge container still exists.

## Cross-references

- `plan/issues/mirror-readiness-gate-seeded-not-reachable-2026-07-23.md` — the mirror readiness gate (relevant to Option B's relay reachability).
- `plan/issues/forge-launch-must-guarantee-fresh-checkout-idempotency-2026-07-20.md` — the fresh-checkout wipe that strands overlay commits on relaunch.
- `plan/issues/research-auth-flow-state-machines-2026-07-23.md` + `research-flow-state-event-channel-2026-07-23.md` — a push that silently has "no route" is a `blocked{push, no-route}` state that should be an observable, surfaced FSM state, not a silent failure.
- plan order 112 (forge-harness-auth) — the Vault credential path Option B's relay reuses.
