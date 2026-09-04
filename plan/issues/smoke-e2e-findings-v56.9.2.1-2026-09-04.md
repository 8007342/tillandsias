# Smoke: curl-install + e2e, release v56.9.2.1, pirria (low-end Linux), 2026-09-04

- release under test: `v56.9.2.1` (STABLE, promoted 2026-09-02)
- channel: stable (leader-assigned pin, not the routine `daily` default)
- host: pirria — CachyOS, 4-core, floor-tier benchmarking host
- lane: Linux / Podman, `linux-next`
- discovered_by: `/smoke-curl-install-and-test-e2e`
- sibling heads at start: main `d6d3e3ed9`, linux-next `17ea51aaa`,
  windows-next `d45bbf9fc`, osx-next `724691251`

## PASS

Release `v56.9.2.1` exercised end-to-end from a wiped substrate:
**install clean, init clean, forge run clean.**

| # | Step | Result | Evidence |
|---|---|---|---|
| 1 | curl-install published artifact | PASS `exit=0`, `Tillandsias v56.9.2.1` | `01-install.log`, `01-version.txt` |
| 2 | `podman system reset --force` | PASS `exit=0`, store empty (containers/volumes/images) | `02-reset.log`, `02-empty-store.txt` |
| 3 | `--debug --init` from pristine | PASS `exit=0` in **6m42s** (06:42:12→06:48:54Z); vault `initialized=true sealed=false v=1.18.5` | `03-init.log` |
| 4 | forge lane + agent run | PASS `exit=0` in **71m30s** (06:49:48→08:01:18Z); agent completed MO-FULL and pushed | `04-opencode.log` |
| 4b | egress: proxy alive alongside lane | PASS — no order-298 regression | `04b-containers.txt` |
| 5 | final health check (after all mutating steps) | PASS — vault healthy/unsealed, proxy healthy | `05-health.log` |

The keychain<->volume resync brick (`738059bc`) did NOT reproduce: keyring
lookups missed (`No matching entry found in secure storage`) but the file
fallback recovered both the Shamir share and the root token, and bootstrap
completed with all 12 policies + AppRoles.

Six containers built and healthy from an empty store in under 7 minutes on
4-core floor hardware.

## Ledger claims (order 380)

Row read at `00-ledger-row.txt`. A real per-release row, not a DISTILLED span.

### EXERCISED
- **811-28eh** dev-inference exit(2) / 128-pids ceiling — inference came up
  healthy from a cold store and stayed healthy through the whole forge run.
  This is the claim the floor is best placed to test and it holds.
- **803-49re** vault self-heal asks the key it just unsealed with — a fresh
  init unsealed cleanly via file fallback after both keyring lookups missed.
- **797-thbw** debug-gated stderr echo that killed `set -e` sourcing shells —
  the entire run used `--debug`; no sourcing shell died.
- **mcp-lane** lane socket listener never bound by the live launcher — the lane
  came up and the in-forge agent completed a full cycle, which requires it.
  Indirect: the symptom's absence, not the listener inspected directly.

### NOT APPLICABLE
- **665-zddn** NVIDIA CDI classification — no NVIDIA hardware on this host.
  (Lenovinha/macuahuitl are the lanes for it.)
- **832-me6z** tray broadcast write bounded — ran `TILLANDSIAS_NO_TRAY=1`.

### NOT CHECKED — this lane could have looked and did not
- **959-fpc5** seven pids-limit sites aligned at 4096 — only the *symptom*
  (healthy inference) was observed; the configured values were never read.
- **805-r98w** hardware fingerprint refusing an untrue twin claim.
- **956-llei** litmus runner adjudicator / 36 hidden tests.
- **867-vd4z** ghost-trace gate over yaml + markdown.
- **890-nkdz** `build_check_mix` measurement practice at emission.
- **793-zumy** Reachable/Placed producers.
- **759-vceg** login flow checks authorization not only authentication — no
  login flow was driven.
- **949-uv5k** capability-routing fixture; **702-6jza D1** attach screen-home;
  **952-mrsl** merge runbook epoch versions; approved-UX-strings gate; the
  three born-red litmus repairs.

A PASS here means "install/reset/init/forge-run are sound on floor hardware",
which is narrower than "the release works".

## Findings

Filed as packets from macuahuitl-fedora (this host has no runnable
`tillandsias-plan` binary — see Blocker below — so orders are minted there with
provenance naming pirria). Recorded here so the evidence lives with the run.

1. **PIPESTATUS assertions are void on a non-bash tool shell** (`testing`).
   The runbook's three 727-kmks assertions (§1, §2, §3) expand `${PIPESTATUS[0]}`
   to the empty string under zsh, so `test "$INSTALL_RC" -eq 0` compares against
   `""` and walks past a failed install. Reproduction: `01-install-exit.txt` from
   the first attempt reads literally `install_exit=`. This is the exact defect
   727-kmks was written to kill, reintroduced by shell choice rather than code.
   Every assertion in this run was re-executed under explicit `bash -c`; the
   PASSes above are real, not inherited from a void check.

2. **`podman system reset --force` does not make a clean room** (`testing`,
   `podman`). `/tmp/tillandsias-ca/` survives the reset (intermediate.crt/key,
   vault.crt/key, mtime 2026-09-03 23:40) and the "pristine" `--init` refreshed
   its vault TLS podman secrets *from that surviving material*. §2 asserts the
   podman store is empty and calls the result pristine; the CA lives outside the
   store. Fix must clear `ca_dir()` via `scripts/lib-ca-path.sh` — never a
   hardcoded `/tmp`, or 998-3z6g relocates the hole to the new path.

3. **`$0` inside the skill body is destroyed by argument substitution**
   (`testing`). `SKILL.md` §0.2/§0.2b awk at lines 79/86/106/113 uses `$0`; the
   skill runtime substitutes it with the first argument, which for a smoke is
   always the tag. The ledger-row match and the DISTILLED arm are therefore dead
   by construction on every host that passes a tag. Corrected awk is the only
   reason this run read a real row.

4. **Release lag, not a defect** (recorded as an event on 998-3z6g).
   v56.9.2.1 ships the CA in `/tmp`, which is what 998-3z6g names. Already
   fixed and merely unreleased: `44a33f328` landed 2026-09-03T22:20-0700, the
   release was cut 2026-09-02T09:19-0700. The preflight's `ca-absent` complaint
   about `~/.local/state/tillandsias/ca` is the NEW path describing a host
   running the OLD release — consistent, not a fault. Confirmed independently on
   a live proxy by lenovinha.

### Floor-tier findings from inside the forge

5. **The spec-index build is impractical on 4-core floor hardware.**
   `embed=23154 of 23154, reused=0` — a *delta* build that reused nothing, i.e.
   a full rebuild. Ran >42 min without completing (~41MB staged
   `new-vecs.jsonl`), was killed to free CPU for the mandatory gate, and the
   partial work is not resumable. The in-forge agent spent the majority of its
   cycle blocked on it. The `reused=0` is the part worth attention: if a delta
   build never reuses, this cost is paid every cycle, not once.
   Bearing on the toolchain question: on a 4h cadence, a ~45min index build is a
   large fraction of the budget, so "install cargo and the expert system works
   here" does not follow.

6. **`./build.sh --check` cannot coexist with the index build on this host.**
   The gate timed out at 10 min under CPU contention and only passed once the
   index build was killed. On floor hardware these must be serialized.

7. **Not filed, deliberately:** seven `invalid peer certificate: BadSignature`
   vault probe retries at `01-install.log:103-110`, self-healed by relaunch.
   Observed on the *dirty pre-reset* host in the already-reported `ca-absent`
   state; the post-reset init was clean. Attributable to host state, not to the
   release. Recorded so a later reader does not rediscover and file it.

8. **Guard against a false regression report:** `04-opencode.log:3` carries
   `no active lane containers; cleaning project + shared stack`, the exact trace
   §4b names as the order-298 actor — but with a `keeping application-lifetime:`
   clause that spares vault/proxy/router/nix-cache. The trace's presence is not
   the bug. Grepping for that string alone will file a false 298 regression;
   assert the proxy's liveness (as §4b does) instead.

## Blocker (not a smoke finding)

The Rust toolchain has vanished from pirria between 2026-09-03T00:26Z and
2026-09-04. `cargo`/`rustc`/`rustup` absent; `$HOME/.cargo` and `$HOME/.rustup`
do not exist; `pacman -Q rust rustup` reports neither installed; no PATH edit in
`~/.bashrc`/`~/.profile`. This is NOT the 876-irn7 false positive (that
resolution path ran and found nothing).

Consequences observed this cycle:
- `scripts/cycle-preflight.sh` → `blocked:preflight:plan:cargo-absent`; the
  smoke ran under the documented `CYCLE_PREFLIGHT_SKIP_BUILD=1` seam because the
  assigned work compiles nothing and selects nothing.
- `plan_next` → `unsupported: degraded(not-built)`.
- `check-capability-row.sh` → `unavailable:no-runnable-plan-binary`; the row
  (last published 2026-08-23) could not be refreshed.
- Neither `target/release/tillandsias-plan` nor `~/.local/bin/tillandsias-plan`
  exists, so no survivor carried through the clean tree.

Also worth a packet: `cycle-preflight.sh` declares `cargo-absent` at line 116
*before* `resolve_plan_binary` at line 144 ever looks for a runnable binary, and
the `CYCLE_PREFLIGHT_SKIP_BUILD` seam that lets a compile-free cycle proceed is
named nowhere in the skill. On a floor host that is the difference between a
lost 4h slot and a completed release smoke.

Toolchain restoration is on the operator queue, not on this host.
