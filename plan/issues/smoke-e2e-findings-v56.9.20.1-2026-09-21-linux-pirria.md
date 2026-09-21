# Smoke e2e findings — v56.9.20.1 (daily) — Linux — pirria

- run_start: 2026-09-21T01:00:56Z
- evidence_dir: target/smoke-e2e   (previous runs archived under _archived-20260921t010056z/)
- forge_lane_outcome: NOT REACHED — the run halted at §1 (see below). §4 did not run.
- signature_verification: cosign:could-not-run:cosign-absent

**VERDICT: FAIL (signatures unverified: cosign absent).** The published Linux
artifact of v56.9.20.1 cannot be installed: `install.sh` calls `--reset-state`
and the published binary refuses the flag, exiting 2.

`cosign:could-not-run` is not a pass and not a failure — this host has no cosign,
so authenticity was not established either way. It is recorded in the opening
lines because a reader who sees only a verdict must not be able to miss it.

## What ran, and where it stopped

| Step | Result |
|---|---|
| §0 pre-flight | PASS — evidence archived, no stale files survived, ledger row present |
| §1 curl-install | **FAIL — `install_exit=2`** |
| §1s signature | could-not-run (cosign absent) |
| §2 destructive reset | **NOT RUN** — the runbook halts on a bad install; this host's substrate is intact |
| §3, §3b, §4, §4a–c | NOT RUN |

Halting at §1 is the runbook's own rule ("the rest of the smoke is invalid on a
bad install"). Per the coordinator's fix-forward ruling, §2 does not run on this
tag on any host; the re-run is against the fix-forward tag.

## Ledger claims

The row for v56.9.20.1 claims the install reset contract on all three platforms
(1286-4437): `--reset-state` destroys local state, preserves the installation
identity, announces before touching anything, reprovisions synchronously, and
every installer calls it by default.

- **EXERCISED — and FAILED.** The Linux installer does call `--reset-state` by
  default (confirmed in the tagged `scripts/install.sh`, whose guarded call sits
  behind the executable check), and the published Linux binary rejects it. The claim's *installer* half is true; its
  *binary* half is not, on this platform.
- **NOT APPLICABLE.** The macOS ungated-module guard and the Windows tray arm —
  other platforms' lanes. (Coordinator verified both trays are unaffected: the
  Windows tray lists the flag in its `KNOWN_FLAGS`; the macOS tray has no
  allow-list.)
- **NOT CHECKED.** Everything downstream of the install: the reset's
  announce-before-destroy ordering at runtime, the preservation of
  `installation-uuid-v1`, synchronous reprovisioning, and the
  `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0` opt-out's runtime behaviour. The install
  failed before any of them could be observed. Also not checked: the content-hash
  plan binary on the installed tree (1287-h6qn) and `./build.sh --preflight` on a
  fresh checkout (1305-udgs), both of which the coordinator named for this lane
  and both of which sit downstream of a working install.

### Work Packet: smoke-finding/install-sh-calls-a-flag-the-binary-refuses

- id: `smoke-finding/install-sh-calls-a-flag-the-binary-refuses`
- owner_host: linux
- capability_tags: [rust, release, install, testing]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.20.1`
- evidence:
  - `target/smoke-e2e/01-install.log` — `Unsupported option: --reset-state` after
    `Running tillandsias --reset-state (resets local state, then reprovisions…)`
  - `target/smoke-e2e/01-install-exit.txt` — `install_exit=2`
  - `v56.9.20.1:crates/tillandsias-headless/src/main.rs` — the `reset_state` read
    from `user_args`; the `known_flags` array (seven entries, neither reset flag);
    the `Unsupported option` refusal that exits 2; the `run_reset_guest` and
    `run_reset_state` dispatches
  - THE ORDERING IS THE DEFECT, and in an immutable tag the line numbers are the
    evidence for it: parse 436 < allow-list 612-651 < refusal 664 < dispatches
    930/942, so neither dispatch is reachable <!-- cite-ok: the defect IS the relative order of these sites inside a frozen tag; a symbol name cannot express "before" -->
  - `v56.9.20.1:scripts/install.sh` — the `say "Running tillandsias --reset-state`
    line and the `"$INSTALL_PATH" --reset-state --debug` call beneath it
- repro:
  - `curl -fsSL "$SMOKE_BASE/install.sh" | TILLANDSIAS_RELEASE_BASE="$SMOKE_BASE" bash`
  - or directly: `~/.local/bin/tillandsias --reset-state --debug` → exit 2
- next_action: >
    FIXED FORWARD at salvage/pirria/20260921-1286-reset-state-allowlist
    (33c4e0aa9): both entries added, plus scripts/test-reset-flags-are-accepted.sh
    which RUNS the binary (4/7 pre-fix, 7/7 post-fix) and
    flag_surface_tests::every_dispatched_flag_is_in_the_known_flags_allow_list,
    mutation-proven. `--reset-guest` is absent from the same list with its
    dispatch at :930 — REJECTED BY READING THE SAME BRANCH, NOT MEASURED, because
    measuring it costs a host's substrate. This packet closes when the
    fix-forward tag installs on this lane.
- events:
  - type: discovered
    ts: `2026-09-21T01:01:08Z`
    agent_id: `linux-pirria-claude-20260921t010056z`
    host: linux

### Work Packet: smoke-finding/litmus-arm-counted-mentions-not-acceptance

- id: `smoke-finding/litmus-arm-counted-mentions-not-acceptance`
- owner_host: any
- capability_tags: [testing, litmus, fail-loud, agent-safety]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.20.1`
- evidence:
  - `openspec/litmus-tests/litmus-installer-reprovisions-on-install.yaml` step 1:
    `n=$(grep -c -- '--reset-state' crates/tillandsias-headless/src/main.rs); [ "$n" -ge 4 ]`
  - that count is **12** on the tree whose binary refuses the flag; the arm
    reported `[PASS] litmus:installer-reprovisions-on-install` 7/7 on trunk
- repro:
  - run the arm on any tree where `known_flags` lacks `--reset-state`: it passes
- next_action: >
    Replace the mention-count with the runtime probe
    (scripts/test-reset-flags-are-accepted.sh, shipped in 33c4e0aa9) and audit the
    corpus for sibling arms that assert a FLAG or a SYMBOL "exists" by counting
    occurrences in source. The class is: a source scan cannot distinguish a flag
    that works from a flag that is merely written down, and help text, comments
    and the parse arm all satisfy the count.
- events:
  - type: discovered
    ts: `2026-09-21T01:12:00Z`
    agent_id: `linux-pirria-claude-20260921t010056z`
    host: linux

### Work Packet: smoke-finding/runbook-distilled-span-compares-versions-lexically

- id: `smoke-finding/runbook-distilled-span-compares-versions-lexically`
- owner_host: any
- capability_tags: [testing, release, skills]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.20.1`
- evidence:
  - `target/smoke-e2e/00-ledger-row.txt` — the exact per-release row for
    v56.9.20.1 AND the distilled span `v56.8.31.3 … v56.9.5.1`, plus
    `(DISTILLED span — claims are series-level, not per-release)`
  - §0.2b's awk compares `tag >= lo && tag <= hi` as STRINGS: `v56.9.20.1` sorts
    between `v56.8.31.3` and `v56.9.5.1` because `2` < `5` at the character level
- repro:
  - run §0.2b with `SMOKE_TAG=v56.9.20.1` against the current README
- next_action: >
    Compare version components numerically, or anchor the span arm so it only
    fires when the exact arm did not. Harmless on this run because the exact arm
    matched first and set `found` — but on a tag with NO exact row it reports a
    span that does not cover it, which is the difference between "this release was
    described" and "nobody described this release", and §0.2b exists to tell those
    apart.
- events:
  - type: discovered
    ts: `2026-09-21T01:02:00Z`
    agent_id: `linux-pirria-claude-20260921t010056z`
    host: linux
