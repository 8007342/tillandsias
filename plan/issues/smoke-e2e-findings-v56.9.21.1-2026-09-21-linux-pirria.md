# Smoke e2e findings — v56.9.21.1 (daily) — Linux — pirria

- run_start — 2026-09-21T05:09:24Z
- evidence_dir: target/smoke-e2e   (previous run archived under _archived-20260921t050924z/)
- forge_lane_outcome: cold-host guard stop (EXPECTED PASS) — the lane brought the
  enclave up and stopped at the Credential Channel Guard. Nothing claimed,
  drained, filed or committed; tree pristine; NO `MO-FULL:` marker emitted, and
  its absence is correct.
- signature_verification: cosign:could-not-run:cosign-absent

**VERDICT: PASS (signatures unverified: cosign absent).**

This is the fix-forward re-run after v56.9.20.1 shipped uninstallable on Linux.
**The defect is repaired on the published artifact:** `install_exit=0`, and zero
`Unsupported option` lines.

AUTHORISATION: pirria is the dedicated Linux smoke host and the destructive steps
are pre-authorised by the operator. §1 IS a destructive step on this release —
`install.sh` calls `--reset-state` itself (1286-4437) — so the pre-state was
captured BEFORE §1 rather than before §2.

`cosign:could-not-run` is neither a pass nor a failure: this host has no cosign,
so authenticity was not established either way (row 1324-ujvb).

## What ran

| Step | Result |
|---|---|
| §0 pre-flight | PASS — evidence archived, no stale files survived, ledger row present |
| §1 curl-install (DESTRUCTIVE on this release) | **PASS — `install_exit=0`, zero `Unsupported option`** |
| §1s signature | could-not-run (cosign absent) |
| §2 destructive reset + credential clear | PASS — clean room on all four surfaces |
| §3 pristine init | PASS — `init_exit=0`, zero failure-class hits, vault healthy |
| §3b shutdown | PASS — vault stopped in 1s against a 10s grace, exit 0 |
| §4 forge lane | cold-host guard stop (expected) |
| §4b egress | PASS — the application-lifetime clause present; proxy alive |

## Ledger claims

The row claims the install reset contract on all three platforms (1286-4437).

**EXERCISED**

1. **The fix (acceptance of 33c4e0aa9).** `install_exit=0`; `grep -c "Unsupported
   option" 01-install.log` → **0**. The published installer's `--reset-state`
   call is accepted by the published binary.
2. **Version.** `tillandsias --version` → `Tillandsias v56.9.21.1`.
3. **The reset contract, MEASURED against a pre-state captured before §1:**

   | | pre | post | |
   |---|---|---|---|
   | containers | 5 | 0 | destroyed |
   | volumes | 7 | 0 | destroyed |
   | images | 16 | 15 | **all recreated** — 0 predate run_start |
   | builder toolbox | 1 | 0 | destroyed (expected) |
   | model cache | 49 files, digest `671701f5a7b6de22` | **identical** | **preserved** |

   The announcement named what it would destroy AND preserve before touching
   anything, and the item it named preserved is the same one measured intact.
4. **Plan binary on the installed tree.** `ok:validator-surface:b1d6bcc42be30c85`
   — after a rebuild the cut itself made necessary (see packet below).
5. **Front door.** `./build.sh --preflight` completed in 138 s, inside its 150 s
   budget.

**NOT APPLICABLE** — the macOS and Windows arms of the reset contract; the two
operator skills; the mirror lane's server half.

**NOT CHECKED** — `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0`'s runtime behaviour on
this release (the opt-out path was not exercised; the fixture covers it on
`--reset-guest` only, because the `--reset-state` opt-out path calls `run_init`
and provisions). The `--preflight` verdict line's ran/skipped counts, because a
re-run I started concurrently with §2 was invalidated by the reset — the wall
time is from the clean first run. Guest-container shutdown inside a VM (Linux
has no VM lane). The forge-internal findings stream, since the lane stopped at
the guard before doing cycle work.

### Work Packet: smoke-finding/cold-state-probe-is-only-truthful-before-init

- id: `smoke-finding/cold-state-probe-is-only-truthful-before-init`
- owner_host: any
- capability_tags: [testing, release, vault, fail-loud, instrument]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.21.1`
- evidence:
  - `target/smoke-e2e/03-credential-cold.md` — verdict `credential-warm`, and in
    its own words: "Vault recovered this pre-existing share. **The keychain-volume
    resync path was NOT exercised by this run** (900-z3kv)."
  - the share it found was created during THIS run — created stamp
    2026-09-21T05:57:09Z against a run_start of 2026-09-21T05:09:24Z
  - `target/smoke-e2e/02-reset.log` — before init, the clearer answered
    `ok:clear-vault-credentials:nothing-to-clear`
  - `target/smoke-e2e/03-init.log` — `preserving existing data volume` appears
    **0** times, and the init logged `keyring Shamir share get failed/timed out
    (No matching entry found in secure storage)`
- repro:
  - run `scripts/probe-credential-cold-state.sh --format=md` at any point AFTER a
    successful `--init`
- next_action: >
    The probe answers a question about the PAST using only the PRESENT, so run
    after init it cannot distinguish "a pre-existing share kept the room warm"
    from "this run's init created the share" — and it renders a confident verdict
    either way, including the claim that the resync path was not exercised. Two
    candidate fixes: compare the item's creation stamp against `run_start` and
    report `credential-cold (share created by this run at …)`, or have the
    runbook state that the probe MUST be taken before §3 and treat a post-init
    reading as `could-not-run`. The runbook currently says to run it and paste
    its block without saying when, so a reader following it literally files a
    false "NOT exercised" claim — which is the exact sentence 900-z3kv exists to
    make checkable.
- events:
  - type: discovered
    ts: `2026-09-21T06:05:00Z`
    agent_id: `linux-pirria-claude-20260921t050924z`
    host: linux

### Work Packet: smoke-finding/clearer-announces-preserving-an-anchor-that-is-absent

- id: `smoke-finding/clearer-announces-preserving-an-anchor-that-is-absent`
- owner_host: linux
- capability_tags: [vault, release, fail-loud]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.21.1`
- evidence:
  - `target/smoke-e2e/02-reset.log` —
    `ok:clear-vault-credentials:nothing-to-clear (preserved: keychain:installation-uuid-v1)`
  - `target/smoke-e2e/00-pre-state.txt` — `secret-tool lookup` for that item
    returned nothing before §1; the digest recorded there is the SHA-256 of EMPTY
    input (`e3b0c442…`), not a value, and there is no `fallback_installation-uuid-v1`
- repro:
  - run `scripts/clear-vault-host-credentials.sh` on a host with no
    `installation-uuid-v1` keychain item
- next_action: >
    The behaviour is right — preserving nothing is correct and `nothing-to-clear`
    is accurate. The LINE is the defect: `preserved: keychain:installation-uuid-v1`
    reads as positive evidence that the installation anchor survived the reset,
    and on a host without that item it is evidence of nothing. 803-49re makes the
    anchor's survival load-bearing, so an auditor checking exactly that will take
    this line as a yes.

    THE REMEDY IS ALREADY WRITTEN, ON ANOTHER SURFACE. macneo hit the same
    defect on macOS and fixed it (their F2,
    plan/issues/smoke-macos-v56.9.21.1-macneo-2026-09-21.md): the announcer in
    crates/tillandsias-macos-tray/src/reset_state.rs probes
    `kc_present(PRESERVED_ANCHOR)` and, when the item is absent, prints
    `[ABSENT BEFORE THIS RESET — nothing to preserve; the next vault will not
    derive from it (803-49re). This reset neither caused nor repairs that.]`
    — their own comment calls it "not a warning dressed as reassurance", which
    is exactly the failure this packet names. Linux simply never got it.

    THE EXACT SITE: scripts/clear-vault-host-credentials.sh sets
    `_kept="$_kept keychain:$ANCHOR_ATTR"` UNCONDITIONALLY, with no presence
    probe, and the final line interpolates it. Mirror the macOS shape with a
    `secret-tool lookup` guard at that assignment; the wording is already
    decided, so this is a port rather than a design.
- events:
  - type: discovered
    ts: `2026-09-21T06:00:00Z`
    agent_id: `linux-pirria-claude-20260921t050924z`
    host: linux

### Work Packet: smoke-finding/head-matches-origin-false-alarms-when-trunk-moves

- id: `smoke-finding/head-matches-origin-false-alarms-when-trunk-moves`
- owner_host: any
- capability_tags: [testing, release, skills]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.21.1`
- evidence:
  - `target/smoke-e2e/04a-cold-host-residue.txt` — `head_matches_origin=no`
  - the checkout's HEAD is an ANCESTOR of `origin/linux-next`, which moved 5
    commits during this smoke; `git status` was empty and the lane committed
    nothing
- repro:
  - run §4a-cold's residue block on any host whose smoke outlasts a trunk land
- next_action: >
    §4a-cold reads `head_matches_origin` as evidence that the lane left nothing
    behind, but it compares against a MOVING ref: on a smoke that takes an hour,
    trunk lands make it `no` regardless of what the lane did. Compare against the
    HEAD recorded at run_start, or assert ancestry rather than equality. As
    written it produces a false alarm exactly on the long runs where the forge
    lane is most likely to have done something.
- events:
  - type: discovered
    ts: `2026-09-21T06:15:00Z`
    agent_id: `linux-pirria-claude-20260921t050924z`
    host: linux

### Work Packet: smoke-finding/a-release-cut-invalidates-every-hosts-plan-binary

- id: `smoke-finding/a-release-cut-invalidates-every-hosts-plan-binary`
- owner_host: any
- capability_tags: [plan, release, tooling, low-end]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.21.1`
- evidence:
  - `target/smoke-e2e/01-plan-binary.txt` — `stale:validator-surface
    built-from=5d2547def2fb88ec checkout=b1d6bcc42be30c85` on a binary that was
    current before the cut
  - after a rebuild: `ok:validator-surface:b1d6bcc42be30c85`, matching the hash
    the stale verdict had named
- repro:
  - hold a current plan binary, take a release cut, re-run
    `tillandsias-plan validator-surface-hash --check`
- next_action: >
    The version bump touches `Cargo.toml`, which is on the validator-surface
    manifest, so every cut makes every host's plan binary content-stale and shuts
    the plan-only lane until each host spends a rebuild. This is CORRECT
    behaviour — the surface genuinely changed — and it is a recurring fleet-wide
    cost that was invisible before 1287-h6qn made currency a content question.
    Worth deciding deliberately: either the release flow rebuilds and re-stamps,
    or the manifest excludes the version field on the grounds that a version bump
    cannot change what validate-yaml accepts. The second needs a negative control
    proving no other Cargo.toml field rides along with it.
- events:
  - type: discovered
    ts: `2026-09-21T05:50:00Z`
    agent_id: `linux-pirria-claude-20260921t050924z`
    host: linux

## Notes that are not findings

- **§1 leaves no running containers, and that is correct.** `--reset-state`
  reprovisions by rebuilding IMAGES synchronously; the log ends `SUCCESS web`,
  "Reset and reprovision complete", exit 0, and directs the operator to launch
  the tray. Containers arrive at tray or lane launch. A reader checking
  `podman ps` after a successful install could file this as a failed provision.
- **A `--preflight` measurement was invalidated by my own concurrency.** I ran it
  while §2's reset was in flight and it died with `no container with ID … found
  in database`. Guards sharing substrate must not run beside a reset — the hazard
  1314-2mdv names, demonstrated rather than argued. The 138 s figure reported
  above is from the clean earlier run.
- Previously filed and still open from the v56.9.20.1 report: the §0.2b DISTILLED
  arm's lexical version comparison, and the mention-counting litmus arm (the
  latter now replaced by `scripts/test-reset-flags-are-accepted.sh`).
