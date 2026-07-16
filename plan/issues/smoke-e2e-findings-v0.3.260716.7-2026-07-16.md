# Smoke e2e findings — release v0.3.260716.7 (macOS, 2026-07-16)

Run by `/smoke-curl-install-and-test-e2e` (channel `daily`, tag
`v0.3.260716.7`, base `releases/download/v0.3.260716.7`) on macOS
(Apple Silicon), agent macos-Tlatoanis-MacBook-Air-fable5-20260716T1024Z,
osx-next @ d25c4598. Destructive substrate reset: 17G
`~/Library/Application Support/tillandsias` + caches wiped after backup-less
sanction (vault held no secrets; token 404).

### Work Packet: smoke-finding/install-macos-bash32-ellipsis-unbound

- id: `smoke-finding/install-macos-bash32-ellipsis-unbound`
- owner_host: any            # scripts/install-macos.sh, shell-portability
- capability_tags: [release, install, shell, macos]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260716.7`
- evidence:
  - `target/smoke-e2e/01-install-macos.log:21` — `bash: line 190: DIAG_PIN…: unbound variable`
  - installer line 189: `say "installed: version=$DIAG_VERSION pin=$DIAG_PIN…"` — the
    trailing `…` is a UTF-8 ellipsis (e2 80 a6) directly abutting the
    expansion; macOS system bash 3.2 folds the multibyte char into the
    variable name, and under `set -u` the script dies at the breadcrumb.
- repro:
  - `curl -fsSL <base>/install-macos.sh | bash` on stock macOS (bash 3.2)
    WITH jq installed (the breadcrumb is inside `if command -v jq`; hosts
    without jq skip the buggy line — why CI's runners may not catch it).
- blast radius: install itself COMPLETES (extract to /Applications happens
  before the breadcrumb) but the script aborts mid-verification, skipping
  everything after line 190 and reporting an error to the operator on an
  otherwise-good install. Confidence in the installer is the casualty.
- next_action: >
    Replace `pin=$DIAG_PIN…` with `pin=${DIAG_PIN}...` (braced expansion +
    ASCII dots) in scripts/install-macos.sh; sweep the installer for other
    non-ASCII chars adjacent to expansions (`grep -nP '[^\x00-\x7F]'`).
    Verifiable closure: a litmus that runs the installer body through
    `bash -u -n` AND asserts no non-ASCII byte abuts a `$` expansion.
- events:
  - type: discovered
    ts: "2026-07-16T10:40:00Z"
    agent_id: "macos-Tlatoanis-MacBook-Air-fable5-20260716T1024Z"
    host: macos
  - type: progress
    ts: "2026-07-16T10:55:00Z"
    agent_id: "macos-Tlatoanis-MacBook-Air-fable5-20260716T1024Z"
    host: macos
    commits: [e15d34fe]
    summary: >
      Hot fix landed on osx-next (braced ASCII-only expansion + non-ASCII
      sweep clean; ships with the next release). Packet narrowed to the
      remaining verifiable closure: the bash -u -n + no-non-ASCII-abutting-
      expansion litmus.
  - type: done
    ts: "2026-07-16T11:50:00Z"
    agent_id: "macos-Tlatoanis-MacBook-Air-fable5-20260716T1124Z"
    host: macos
    commits: [e2b6bf06]
    summary: >
      Verifiable closure landed: litmus:installer-ascii-expansion-safety
      (bash -n + perl byte-level expansion-adjacency guard; catches the
      original defect on a fixture, passes the fixed tree). Same commit
      fixes build-macos-tray.sh to stage target-guest/, turning
      litmus:guest-binary-embed-integrity green on macOS — ci-release
      suite 5/5. Packet CLOSED.

### Work Packet: smoke-finding/resolver-races-inflight-release-workflow

- id: `smoke-finding/resolver-races-inflight-release-workflow`
- owner_host: any            # scripts/resolve-smoke-release.sh
- capability_tags: [release, testing, ci]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260716.7`
- evidence:
  - first install attempt at 10:25Z: `curl: (56) The requested URL returned
    error: 404` for install-macos.sh — release workflow run 29489702625 was
    still `in_progress`; the Linux job had published the release (and its
    assets) while the macOS job was still building. Asset appeared at
    10:34Z when the job concluded.
- repro:
  - run the smoke within ~15 minutes of a release dispatch; per-host assets
    land per-job, so the resolved tag exists with an incomplete asset set.
- next_action: >
    Teach scripts/resolve-smoke-release.sh (or the skill pre-flight) to
    verify the release workflow run for the resolved tag has concluded —
    or minimally that THIS host's installer asset HEADs 200 — before
    handing the tag to the smoke; emit `pending:<tag>` as a structured
    verdict so callers wait instead of filing false 404 findings.
- events:
  - type: discovered
    ts: "2026-07-16T10:35:00Z"
    agent_id: "macos-Tlatoanis-MacBook-Air-fable5-20260716T1024Z"
    host: macos

### Work Packet: smoke-finding/skill-macos-verify-path-mismatch

- id: `smoke-finding/skill-macos-verify-path-mismatch`
- owner_host: macos          # skills/smoke-curl-install-and-test-e2e/SKILL.md
- capability_tags: [testing, docs, macos]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260716.7`
- evidence:
  - skill §1 macOS verify line reads
    `"$HOME/Applications/Tillandsias.app/..." --version` but
    scripts/install-macos.sh installs to `/Applications/Tillandsias.app`
    (log: "extracting to /Applications/Tillandsias.app"). On a host with a
    stale copy under ~/Applications the skill "verifies" the WRONG binary
    and can misattribute versions (exactly what happened this run before
    the real target was checked).
- next_action: >
    Fix the skill's verify path to /Applications (or better: parse the
    "Installed:" line from the installer output). One-file doc change.
- events:
  - type: discovered
    ts: "2026-07-16T10:40:00Z"
    agent_id: "macos-Tlatoanis-MacBook-Air-fable5-20260716T1024Z"
    host: macos
  - type: done
    ts: "2026-07-16T10:55:00Z"
    agent_id: "macos-Tlatoanis-MacBook-Air-fable5-20260716T1024Z"
    host: macos
    commits: [e15d34fe]
    summary: "Skill §1 macOS verify path fixed to /Applications (canonical skills/ file; .claude symlink follows)."

## Steps 2-3 (PASS)

- Substrate reset: 17G VM state + caches removed; pristine.
- `--provision` from the release manifest: clean exit 0 — 528 MB Fedora
  Cloud image downloaded, converted, resized; `--diagnose --json` reports
  `provisioned: true` (release_tag fedora-44).

## Step 4 (in-forge smoke from pristine substrate) — harness PASS, in-forge litmus grading FAIL

The release-carried goal chain worked from NOTHING: pristine substrate →
`--provision` → all five enclave images built from the release's embedded
assets (proxy, router, git, inference, forge-base, forge; zero build
errors) → lane launched with NO vault refusal (the v0.3.260716.7-shipped
ForgeLaunch vault ensure engaging silently) → **big-pickle inside OpenCode
inside the forge ran the full smoke runbook and emitted a well-formed
verdict** → clean teardown, tray exit 0.

The verdict itself was `MO-SMOKE: FAIL 7 code/spec regressions
(cheatsheet-source-layer, cheatsheet-host-image-sync,
cheatsheet-tier-discipline, guest-binary-embed-integrity,
default-image-containerfile-shape, forge-opencode-onboarding,
forge-standalone-runtime) + 3 environmental (podman stall ×2, missing cmp
binary)`. Full failing set (142 PASS / 10 FAIL):
cheatsheet-source-layer-validation, cheatsheet-host-image-sync,
cheatsheet-tier-discipline, guest-binary-embed-integrity,
default-image-containerfile-shape, forge-opencode-onboarding-shape,
forge-standalone-runtime-shape, meta-orchestration-dirty-tree-safety,
runtime-diagnostics-stream-shape, podman-path-availability.

### Work Packet: smoke-finding/inforge-litmus-context-eligibility-and-verdict-grammar

- id: `smoke-finding/inforge-litmus-context-eligibility-and-verdict-grammar`
- owner_host: linux           # litmus runner + meta-orchestration skill seam
- capability_tags: [litmus, forge, testing, meta-orchestration]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260716.7`
- evidence:
  - this run: 10 in-forge litmus FAILs → `MO-SMOKE: FAIL`; the 08:27Z
    in-forge smoke on the same host saw the same failure classes
    (cheatsheets ×3, guest-binary-embed, onboarding, podman, cmp) and
    graded `MO-SMOKE: PASS` calling them pre-existing/known.
  - several failures are context-INELIGIBLE rather than regressions:
    podman-path-availability and guest-binary-embed-integrity cannot
    succeed inside a forge (no podman binary; no staged target-guest/),
    and the cheatsheet-sync trio measures host↔image drift that a forge
    clone cannot resolve.
- repro: run the pre-build instant litmus sweep inside any forge lane.
- next_action: >
    Two slices: (1) add host-kind eligibility gates (skip-with-reason) to
    the ~7 tests that are structurally ineligible in-forge, mirroring the
    existing 132-skip mechanism; (2) make the Smoke Mode runbook's verdict
    grammar explicit about known/pre-existing failures (e.g. FAIL only on
    NEW failures relative to plan-recorded state) so two same-day runs
    cannot grade the same state PASS and FAIL.
- events:
  - type: discovered
    ts: "2026-07-16T11:20:00Z"
    agent_id: "macos-Tlatoanis-MacBook-Air-fable5-20260716T1024Z"
    host: macos

### Small captures (deduped)

- `[entrypoint] WARNING: OpenSpec init failed — /opsx commands may not
  work` on lane start (04-opencode.log:16) — forge onboarding gap, likely
  the same surface as forge-opencode-onboarding-shape's FAIL; folded into
  the packet above rather than filed separately.
- meta-orchestration-dirty-tree-safety FAIL in-forge is consistent with
  the already-filed lane self-dirty lockfile issue
  (plan/issues/forge-lane-selfdirty-opencode-lockfile-2026-07-16.md);
  event-noted there implicitly via this report.

## Overall

- Steps 1-3: PASS with two release-channel findings (installer breadcrumb
  death — hot-fixed e15d34fe; resolver/in-flight-workflow race — packet
  open). Step 4: harness-level PASS (the chain the operator goal needs is
  fully carried by the published release, from a wiped host, unattended);
  in-forge litmus grading produced the FAIL verdict — triaged into the
  eligibility/verdict-grammar packet above.

