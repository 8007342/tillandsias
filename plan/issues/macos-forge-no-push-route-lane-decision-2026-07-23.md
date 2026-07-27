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

All three run the SAME enclave-isolated Linux forge (same `tillandsias-headless` crate, `--network tillandsias-enclave`); **isolation never diverged.** What differs is only the per-platform source-staging lane, and one lane (macOS) dropped the push half:

| Platform | Enclave-isolated? | Push route today |
| --- | --- | --- |
| **Linux native** | **YES** (`ENCLAVE_NET` `main.rs:4664`/`:10684`; proxy-only egress; host creds tmpfs-quarantined) | **git:// mirror by DEFAULT** (order 437; `TILLANDSIAS_GIT_SERVICE` `main.rs:10749`/`:4794`) — transparent push works. Opt-in `TILLANDSIAS_FORGE_HOST_MOUNT=1` escape hatch remains (still mirror-pushes; reduced *workspace* isolation) — guard/retire. |
| **Windows / WSL2** | **YES** (same crate in WSL2) | git:// mirror relay (`GIT_SERVICE`). **The correct reference.** |
| **macOS** (VZ VM) | **YES** (SRC-ISOLATION clone lane, order 342) | **NONE.** The lane sets `TILLANDSIAS_GIT_MIRROR_PATH` (`main.rs:4765`) but **never `TILLANDSIAS_GIT_SERVICE`** (`main.rs:4753-4766`) → no `git://` push relay. Same enclave situation as Windows, solved a different way, and that lane skipped the push half. |

**Correction (per the uniform-isolation principle packet `forge-enclave-isolation-uniform-principle-2026-07-23.md`, commit `66de6820`):** an earlier draft of this packet — and my earlier verbal comparison — claimed Linux is "NOT enclave-isolated" and "pushes directly to GitHub with host credentials." That is **WRONG at HEAD.** The Linux forge is enclave-isolated and mirror-pushes by DEFAULT since order 437; the host-checkout mount the operator remembers was the *pre-437 default* (a real quick-fix, since remediated), now only an opt-in escape hatch that STILL rewrites origin onto the mirror (never direct-pushes — "the forge has zero credentials and no DNS for github.com", `lib-common.sh:375`). So isolation is uniform; the **only** residual push divergence is the macOS lane. Windows/WSL2's git:// mirror is the correct reference — and the operator's target refines even it with an explicit **ram-disk (tmpfs) checkout**, confirmed **NET-NEW**: today every lane materializes the working tree on the container overlay (`/home/forge/src/<project>`, `lib-common.sh:477`), not tmpfs.

> CONFIRMED (principle packet `66de6820`): Linux + Windows both use the clone-only default (order 437, `TILLANDSIAS_GIT_SERVICE=tillandsias-git`, `main.rs:10749`/`:4794`) → git:// mirror push. There is **no** Linux direct-push path (refuted). macOS is the only lane missing `GIT_SERVICE`.

## Fix options

### OPTION B — git-mirror + ram-disk checkout + transparent push  *(THE OPERATOR-DIRECTED TARGET)*
**Operator direction (2026-07-23):** the correct architecture, uniform across ALL platforms, is:
1. an internal **git-mirror** (bare mirror of the remote);
2. a **ram-disk (tmpfs) working checkout cloned FROM the mirror** — not a host mount, not a plain disk overlay; an explicit ramdisk for speed + ephemerality + isolation;
3. **transparent pushes to remote** (forge → mirror → remote relay via the Vault token).

This is the same `git://` mirror mechanism Windows/WSL2 already uses, refined with an explicit ramdisk checkout. Wire it for the macOS lane: set `TILLANDSIAS_GIT_SERVICE`, materialize the checkout on tmpfs cloned from `tillandsias-git`, and push to the mirror which relays to GitHub via the Vault token (`relay-refs.sh`, `git-credential-tillandsias.sh`).
- **Pros:** keeps AND strengthens isolation (ephemeral ram-disk, no host residue); parity with the proven Windows mechanism; transparent push, zero manual steps.
- **Cons:** real wiring work — (a) set `TILLANDSIAS_GIT_SERVICE` + make the relay/receive-pack path reachable from the macOS SRC-ISOLATION lane; (b) the **ram-disk (tmpfs) checkout is confirmed NET-NEW** — today every lane clones to the container overlay (`/home/forge/src/<project>`, `lib-common.sh:477`), so materializing the working tree on tmpfs is a new step for macOS *and* the Linux/Windows default; (c) confirm the mirror-readiness gate (see `mirror-readiness-gate-seeded-not-reachable-2026-07-23.md`).

### OPTION A — switch the macOS forge to the HOST-MOUNT lane  *(REJECTED — the legacy anti-pattern)*
> **Operator direction (2026-07-23): DO NOT adopt this.** Host-checkout mounts are the LEGACY pattern — "some legacy implementations on the linux host where it would just mount the host checkout, which is wrong." It was the *pre-order-437* Linux default and has been demoted to an opt-in escape hatch, not copied forward. It reduces the forge's *workspace* isolation, which is the forge's whole purpose.

`TILLANDSIAS_FORGE_HOST_MOUNT=1` bind-mounts the operator checkout **rw** and installs the gitdir facade; it still rewrites origin onto the mirror via `rewrite_origin_for_enclave_push` (`lib-common.sh:397-457`; forge-args branch `main.rs:4767-4781`), so it does NOT lose network/credential isolation.
- **Why rejected:** it reduces *workspace* isolation (agent edits become host-visible without a commit; gitdir-facade data-loss surface) and **resurrects exactly the facade that order 437 obsoleted on Linux** — moving *away* from convergence. Choosing it would repeat the pre-437 shortcut on macOS. Documented here only to record why it is NOT the path.

### OPTION C — `git bundle` export to the virtiofs `~/src` share
A workaround, not a fix: bundle the overlay checkout to the host-visible `~/src`. Preserves nothing about the normal push workflow; only useful for one-off recovery.

## OPERATOR DIRECTION (decided 2026-07-23)

Not an open choice anymore — the operator specified the target: **Option B — git-mirror + ram-disk (tmpfs) checkout-from-mirror + transparent push — uniform across ALL platforms.** Option A (host-mount) is **REJECTED** as the legacy anti-pattern (the Linux host's host-checkout mount is being removed, not copied). Option C is recovery-only. See the uniform forge-isolation principle packet (enclave network + git-mirror + ramdisk checkout + transparent push on every platform).

## Recovery of currently-stranded commits (while a forge is live)

Per the recovery trace: `tillandsias-tray --exec-guest 'podman cp <forge-container>:/home/forge/src/<project> /home/forge/src/<name>-recovery'` lifts the overlay checkout onto the virtiofs `~/src` (= the Mac's `~/src`) WITHOUT running the wiping entrypoint (`podman cp` does not exec). Then push from the Mac normally. Recoverable only while the `--rm` forge container still exists.

## Cross-references

- `plan/issues/mirror-readiness-gate-seeded-not-reachable-2026-07-23.md` — the mirror readiness gate (relevant to Option B's relay reachability).
- `plan/issues/forge-launch-must-guarantee-fresh-checkout-idempotency-2026-07-20.md` — the fresh-checkout wipe that strands overlay commits on relaunch.
- `plan/issues/research-auth-flow-state-machines-2026-07-23.md` + `research-flow-state-event-channel-2026-07-23.md` — a push that silently has "no route" is a `blocked{push, no-route}` state that should be an observable, surfaced FSM state, not a silent failure.
- plan order 112 (forge-harness-auth) — the Vault credential path Option B's relay reuses.

## Windows-lane context (2026-07-24, windows host observer — the "TO CONFIRM" items + a sharper Option B)

Supplied from the host that has run the working push route all week,
including live sequential + concurrent multi-host relay validation across
three harness sessions (opencode, codex, antigravity).

### The exact Windows wiring (confirming the TO CONFIRM block)

Windows does NOT use SRC-ISOLATION at all. The per-lane source routing in
`crates/tillandsias-headless/src/main.rs` is a three-way branch:

- `main.rs:4754-4767` — `TILLANDSIAS_FORGE_SRC_ISOLATION=clone` (macOS
  today, order 342): ro staged mount + `TILLANDSIAS_GIT_MIRROR_PATH`,
  NO git service → no push route. Forced by
  `crates/tillandsias-macos-tray/src/diagnose.rs:1191-1200`.
- `main.rs:4768-4782` — host-mount legacy (Option A).
- `main.rs:4783-4797` — **clone-only DEFAULT (order 437) — what Windows
  runs**: sets `TILLANDSIAS_GIT_SERVICE=tillandsias-git`; the entrypoint
  (`lib-common.sh:584+`) clones the working tree FROM the enclave mirror
  over `git://` and pushes back to the SAME mirror, which relays to
  GitHub (`relay-refs.sh` → `git-credential-tillandsias.sh` → Vault).

### The sharper fix: Option B is really "delete the override"

The clone-only default delivers EVERYTHING order 342's SRC-ISOLATION was
built for — fresh forge-owned checkout, no host mount, no gitdir facade,
no facade data-loss surface — PLUS the push route, because the mirror is
simultaneously clone source and push target. Order 342 predates the
order-437 clone-only default; SRC-ISOLATION=clone on macOS is plausibly
a legacy override that 437 obsoleted. So the recommended Option B likely
reduces to: remove/stop setting `TILLANDSIAS_FORGE_SRC_ISOLATION=clone`
in `diagnose.rs:1191-1200` and let macOS take the same default branch as
Windows. One thing to verify, not build: mirror SEEDING reads the
operator checkout once at lane launch — on macOS that is the virtiofs
`~/src` staging, and seeding only needs read access, so the ro property
order 342 cared about is preserved where it matters.

### Live-verified properties the macOS lane inherits for free

- Relay survived 21+ pushes in one codex session and concurrent
  multi-host pushes without loss (validated 07-23/24 from this host).
- Vault Agent auto-auth (dcafd59c): the relay credential now survives
  token max-TTL for 48h without container restart — the macOS lane gets
  this by using the same mirror image.
- Mirror readiness keys on SEEDED-not-reachable (dec1175e) — the
  first-seed race is already fixed in the shared launcher path.
- NEW-branch pushes through the mirror work as of 322d3026 (order 462
  pre-receive diff-base fix) — agent WIP/salvage branches now relay.
- Known caveat to inherit consciously: relay publication can be
  OUT-OF-ORDER vs author time when multiple worktrees push in one
  session (observed live 07-23; MOT-02 in the meta-orchestration
  technique audit). Downstream consumers must not assume monotonic
  authored-order on linux-next.

### One macOS-specific verification before flipping

The enclave network + aliases (`tillandsias-git`, `git-service`) and the
git-daemon args are identical Linux-podman constructs inside the VZ VM,
so reachability should hold by construction — but the 07-24 windows soak
showed netavark state can rot on long-running VMs (order 463). Run one
attended macOS lane e2e (clone → commit → push → relay → GitHub) before
declaring parity, and reuse
`scripts/test-git-mirror-relay-token-expiry.sh` +
`scripts/test-git-mirror-vault-agent-auto-auth.sh` in the macOS guest.

## OPERATOR DECISION — RESOLVED (Tlatoāni, 2026-07-24)

**Approved: supersede the order-342 SRC-ISOLATION direction with the
order-437 clone-only default** (the mechanism Windows runs in
production). Implementation is the reduced Option B from the
windows-lane context above: remove the
`TILLANDSIAS_FORGE_SRC_ISOLATION=clone` override
(`diagnose.rs:1191-1200`) so the macOS lane takes the shared default
branch (`main.rs:4783-4797`) — mirror clone + mirror push in one
mechanism. Order 342's isolation goal is preserved by construction;
only its mechanism is retired (supersession recorded on the order-342
ledger entry). Dependency order 462 is satisfied (322d3026). Before
declaring parity: one attended macOS e2e push chain, the two
test-git-mirror-*.sh scripts in the VZ guest, and an order-463
netavark-state check.
