# Cheatsheet `tier: committed` is an invalid tier that fails CI-full + blocks the release pipeline — 2026-06-17

Discovered by `/build-install-and-smoke-test-e2e` (linux) while running the
local-build e2e gate to accept `smoke-finding/rootless-bridge-network-missing`.
The build/install gate (`./build.sh --ci-full --install`) fails at the CI
validation phase **before install**, so no host can complete the local-build
e2e or cut a release until this is resolved.

## Summary

`cheatsheets/concurrent-git/commit-attribution.md` (added by order-53 commit
`e31792e8`, agentic git attribution) declares `tier: committed`. No tier
validator in the repo recognizes `committed`, and the two cheatsheet validators
**disagree**, so the same file passes one gate and fails the other:

- `scripts/check-cheatsheet-tiers.sh` → `ALLOWED_TIERS = {bundled,
  distro-packaged, pull-on-demand}` → **ERROR**: `invalid tier 'committed'`.
  (This is the `cheatsheet-tiers` local-ci check → FAIL.)
- `litmus:cheatsheet-tier-discipline` (strict tier validator) → **PASS** for the
  same file (does not reject `committed`).

Coupled failure: `litmus:cheatsheet-host-image-sync` also FAILS because the new
cheatsheet exists only in the host tree:

```
Only in cheatsheets/concurrent-git: commit-attribution.md
Files cheatsheets/INDEX.md and images/default/cheatsheets/INDEX.md differ
```

So order-53 added the cheatsheet to `cheatsheets/` but never synced it into
`images/default/cheatsheets/`, and `cheatsheets/INDEX.md` was regenerated while
the image-tree INDEX was not.

## Evidence (this run)

- `target/build-install-smoke-e2e/<RUN_ID>/01-build-install.log` tail:
  `✗ CHECKS FAILED` → `[1] cheatsheet-tiers`, `[2] litmus-pre-build`.
- `/tmp/cheatsheet-tiers.log`:
  `ERROR: cheatsheets/concurrent-git/commit-attribution.md: invalid tier
  'committed' (must be one of ['bundled', 'distro-packaged', 'pull-on-demand'])`.
- `/tmp/litmus-pre-build.log`:
  `litmus:cheatsheet-host-image-sync` STEP 1/3 FAIL (host/image trees differ);
  `litmus:cheatsheet-tier-discipline` STEP 1/1 OK (accepts `committed`).
- Frontmatter of the offending file:
  `tier: committed`, `bundled_into_image: false`, `committed_for_project: true`.
- Sibling cheatsheets in `cheatsheets/concurrent-git/` (`agent-handoff.md`,
  `branches.md`, `plan-discipline.md`) all use `tier: bundled`.

## Work Packet: cheatsheet/reconcile-committed-tier

- id: `cheatsheet/reconcile-committed-tier`
- type: fix
- owner_host: linux
- status: done (resolved via Option A on 2026-06-17T20:30Z, commit `0eef1443`)
- severity: high — blocks `./build.sh --ci-full --install` (the local-build e2e
  gate) and the `/merge-to-main-and-release` pipeline for all hosts.
- capability_tags: [docs, cheatsheets, tooling, ci, release]
- depends_on: []
- owned_files:
  - cheatsheets/concurrent-git/commit-attribution.md
  - cheatsheets/INDEX.md
  - images/default/cheatsheets/  # if the decision is to bundle it
  - scripts/check-cheatsheet-tiers.sh  # if the decision is to add a tier
  - openspec/litmus-tests/litmus-cheatsheet-host-image-sync.yaml  # if exclusion needed
- decision_required: choose ONE coherent model, then make BOTH validators agree:
  - Option A (match siblings — simplest): retier to `tier: bundled`, set
    `bundled_into_image: true`, sync the file into
    `images/default/cheatsheets/concurrent-git/`, regenerate BOTH INDEX.md trees
    (`scripts/regenerate-cheatsheet-index.sh`). Note: `bundled` warns (not
    errors) pre-build when `image_baked_sha256` is unset.
  - Option B (honor frontmatter intent): retier to `tier: pull-on-demand`
    keeping `committed_for_project: true` — but `check-cheatsheet-tiers.sh`
    then REQUIRES a `## Pull on Demand` section (Source / Materialize recipe /
    Generation guidelines sub-headings + license + bash block). A hand-curated
    methodology cheatsheet has none, so this needs a stub authored or the
    validator relaxed for project-committed pull-on-demand entries.
  - Option C (formalize a new tier): add `committed` to
    `check-cheatsheet-tiers.sh ALLOWED_TIERS` and teach
    `litmus:cheatsheet-host-image-sync` to EXCLUDE `committed`/`bundled_into_image:false`
    cheatsheets from the image-tree parity check. Most faithful to order-53's
    apparent intent, but the largest tooling change.
- recommendation: Option A — it is the lowest-risk way to get CI-full green
  fast (matches the three sibling cheatsheets in the same directory) and unblock
  the release pipeline; revisit Option C as a deliberate tier-model change if a
  repo-committed-but-not-bundled tier is genuinely wanted.
- acceptance_evidence:
  - "`scripts/check-cheatsheet-tiers.sh` (the `cheatsheet-tiers` check) exits 0."
  - "`litmus:cheatsheet-host-image-sync` passes (host and image trees + both
    INDEX.md synchronized)."
  - "`./build.sh --ci-full` reaches a green CHECKS PASSED summary."
- events:
  - type: discovered
    ts: "2026-06-17T20:10:00Z"
    agent_id: "linux-tlatoani-claude-opus-4-8-meta-orchestration"
    host: linux
    note: >
      Surfaced while running the local-build e2e gate to accept the bridge-network
      egress fix. The e2e gate cannot reach install/init/forge because CI-full
      fails on this pre-existing order-53 cheatsheet inconsistency. Filing as a
      separate ready packet; not guess-fixed mid-gate because the tier model is a
      deliberate decision (Options A/B/C above).
  - type: resolved
    ts: "2026-06-17T20:30:00Z"
    agent_id: "linux-tlatoani-claude-opus-4-8-meta-orchestration"
    host: linux
    commit: "0eef1443"
    note: >
      Applied Option A: retiered commit-attribution.md committed→bundled
      (bundled_into_image true), synced into images/default/cheatsheets/
      concurrent-git/, regenerated host INDEX.md and synced image INDEX.md
      byte-identical. Verified: check-cheatsheet-tiers.sh exits 0 (210
      validated); host-image-sync litmus critical_path passes (trees
      byte-identical); ./build.sh --ci-full → ALL CHECKS PASSED (14/14).
      Release pipeline + local-build e2e gate unblocked for all hosts.
