# Release Nix store cache never restored across releases (GHA ref-scoping) — ~10 min wasted every release

- branch: linux-next
- status: ready
- owner_host: any (CI/workflow edit; verification needs a release run)
- source: operator report (Tlatoāni) + meta-orchestration release cycle 2026-06-20, run 27881936382
- pickup: Build/CI-capable worker. Implement one of the fix options below, then
  verify with two consecutive release runs that the `nix build` step time drops
  and the `Post Nix Cache` upload shrinks/disappears. File a `completed` event
  with before/after timings.

## Summary

Every release takes ~45 min, of which the `nix build` step rebuilds the entire
Nix closure from scratch (including the from-source aarch64 cross-GCC) and the
`Post Nix Cache` step then re-uploads a ~2.2 GB store tarball (~10 min) — **on
every single release**. The cache that is supposed to make follow-on builds a
fast delta is **never restored**. This has been silently true for many releases.

The operator's mental model ("Magic Nix Cache") does not match the workflow:
`.github/workflows/release.yml` does **not** use Determinate's Magic Nix Cache —
it uses `nix-community/cache-nix-action@v7` (saves/restores `/nix/store` as a
tarball via the GitHub Actions cache backend). The "pushing to cache" log spam
is the `Post Nix Cache` save step, not a binary cache push.

## Root Cause (confirmed with evidence)

**GitHub Actions caches are ref-scoped, and releases dispatch on fresh tags.**

A workflow run can only *restore* a cache created on (a) its own ref, (b) the
repository default branch (`main`), or (c) in a PR, the base branch. It can
**never** restore a cache created on a *different* tag ref.
(cache-nix-action README: "Caches are isolated for restoring between refs … The
default branch cache is available to other branches.")

The release workflow is `workflow_dispatch` triggered with `--ref vX.Y.Z` — i.e.
it runs on `refs/tags/vX.Y.Z`. So:

1. Release `v0.3.260620.7` builds the closure and saves the 2.2 GB store cache
   under `ref=refs/heads/refs/tags/v0.3.260620.7`.
2. Release `v0.3.260620.8` runs on `refs/tags/v0.3.260620.8`. It looks for the
   cache key `nix-Linux-<flake.lock-hash>` — the key is **identical** (flake.lock
   unchanged) — but the only copies exist under *other tag refs*, which are
   invisible to this run. The `main` default-branch scope has **no** Nix store
   cache. → **guaranteed miss → full rebuild → 2.2 GB re-upload.**

Evidence from `gh api repos/8007342/tillandsias/actions/caches` on 2026-06-20:

```
2196MB ref=refs/heads/refs/tags/v0.3.260620.7  key=nix-Linux-18507b83…  (same key…)
2197MB ref=refs/heads/refs/tags/v0.3.260618.2  key=nix-Linux-18507b83…  (…on each)
2196MB ref=refs/heads/refs/tags/v0.3.260618.1  key=nix-Linux-18507b83…  (…tag ref)
```

Identical key, one isolated copy per tag, zero copies on `main` → never shared.

**Compounding factor — 10 GB eviction.** Repo cache usage is already
`active 10.37 GB > 10 GB limit`. GHA LRU-evicts over the limit, so even the
per-tag copies and the rust-release caches churn against each other.

## Why "magic cache" isn't helping as expected

It was never wired up. The job uses cache-nix-action (GHA-cache-backed,
ref-isolated) and runs on tag refs, which is the worst case for that action.
Magic Nix Cache / FlakeHub Cache are *binary caches* not subject to GHA ref
scoping — that is exactly the property this workflow needs and currently lacks.

## Web research — the right approach (2026)

- **Magic Nix Cache** free tier API was shut down 2025-02-01; the action was
  later revived (jchv) against GitHub's new cache API, but it is reverse-
  engineered and "caches only between runs of a specific workflow in a specific
  repo" — still GHA-cache-backed, so still subject to the same scoping/limit.
  Determinate now positions it as "only when you want better perf between CI
  runs."
- **FlakeHub Cache** (Determinate's current recommendation) is a true
  all-purpose binary cache, org-scoped, **not** ref-scoped and **not** on the
  10 GB GHA budget — "dramatically better performance." Enabled via the
  Determinate Nix installer (`determinate: true`) + FlakeHub Cache, auth via
  `permissions: id-token: write` (free for public repos).
- **cache-nix-action**'s own guidance for the GHA-cache path: purge old caches,
  merge matrix caches, and **populate the default-branch cache** so other refs
  (tags) can restore it.

Sources:
- https://github.com/nix-community/cache-nix-action
- https://determinate.systems/blog/magic-nix-cache-free-tier-eol/
- https://determinate.systems/blog/bringing-back-magic-nix-cache-action/

## Fix Options (pick one; ordered by recommendation)

1. **FlakeHub Cache (recommended).** Switch the Linux release Nix steps to the
   Determinate installer with `determinate: true` + FlakeHub Cache, add
   `permissions: id-token: write`, and drop cache-nix-action for the Nix store.
   Removes ref-scoping and the 10 GB ceiling entirely; cross-GCC builds once and
   is restored on every subsequent release regardless of tag. Cost: a FlakeHub
   account/token; verify the free public-repo tier covers our volume.

2. **Warm the cache on `main` (no external service).** Add a job/workflow that
   runs `nix build .#tillandsias-*-musl` on **push to `main`** (or on a schedule)
   and saves via cache-nix-action under `refs/heads/main`. Tag-dispatched release
   runs CAN restore default-branch caches, so they hit a warm store. Also set
   cache-nix-action `restore-prefixes-first-match`/`-all-matches` to read the
   `main` scope explicitly, and enable its purge inputs to stay under 10 GB.
   Lowest friction, no new dependency; downside is a redundant build on main.

3. **Self-hosted binary cache (Attic / Cachix / S3).** Most control, most setup;
   only if 1–2 are rejected.

Whichever is chosen, also add **cache hygiene**: purge per-tag Nix caches after a
release (they can never be reused) and keep total usage under 10 GB so the
shared/default-branch cache is not evicted.

## Tasks

- id: choose-approach
  status: completed
  action: >
    Decide between FlakeHub Cache (opt 1) and warm-cache-on-main (opt 2). This is
    a cost/dependency decision (FlakeHub account vs redundant main build) — record
    the choice and rationale here. Default recommendation: opt 1 if the FlakeHub
    public-repo free tier is confirmed adequate, else opt 2.
- id: implement-cache-fix
  status: completed
  depends_on: [choose-approach]
  owned_files: [.github/workflows/release.yml]
  action: >
    Implement the chosen approach in release.yml (Linux release job, and consider
    the macOS/Windows jobs which use swatinem/rust-cache under the same tag-ref
    scoping). Add cache purge for unreusable per-tag Nix caches.
- id: verify-incremental
  status: ready
  depends_on: [implement-cache-fix]
  action: >
    Cut two consecutive releases. Assert the second's `nix build` step time and
    `Post Nix Cache`/cache-save bytes drop substantially vs the first. Record
    before/after numbers as a completed event. Closure = a measured delta build.

## Measured evidence (run 27881936382, v0.3.260620.8)

- `Nix Cache` restore step: **0 s** (19:46:19 → 19:46:19) — nothing restored.
- `Build musl-static binaries via Nix`: **~23 min** (19:46:19 → 20:09:19) — full,
  non-incremental closure build despite flake.lock being unchanged.
- `Post Nix Cache` save: only 18 s (20:09:43 → 20:10:01) — i.e. it did **not**
  re-upload the 2.2 GB store. Because the GHA cache key
  `nix-Linux-<flake.lock-hash>` already exists in the repo (saved under prior tag
  refs), GHA refuses a duplicate-key save and cache-nix-action skips it. Net:
  the store **can neither be restored (ref-scoped) nor re-saved (key collision)**
  — every release rebuilds from scratch forever. The lock is effectively frozen.
- **FlakeHub Login failure** in the `Install Nix` step:
  `The process '/usr/local/bin/determinate-nixd' failed with exit code 1`. The
  installer (v22, with `id-token: write` present) *attempts* FlakeHub Cache login
  and fails because the repo is not enrolled on FlakeHub. So FlakeHub is
  **half-wired and broken** — it produces the "magic/flakehub cache" log chatter
  the operator saw while providing **no** caching. Current state is the worst of
  both worlds.

This sharpens the recommendation: option 1 (FlakeHub Cache) is *already
partially in place* — completing it (enroll the repo / fix the login) is likely
the smallest correct change and removes the failing-login noise too. If FlakeHub
enrollment is undesirable, explicitly disable the installer's FlakeHub attempt
AND adopt option 2 (warm-on-main) so something actually caches.

## Events

- type: finding
  ts: "2026-06-20T20:12:00Z"
  agent_id: "linux-claude-opus48-20260620T2012Z"
  host: "linux_mutable (interactive Claude Code CLI)"
  note: >
    Post-build measurement of run 27881936382: 0 s cache restore, 23 min full
    build, 18 s no-op save (duplicate-key skip). Discovered the Determinate
    installer is also failing FlakeHub login (determinate-nixd exit 1) — FlakeHub
    is half-configured (id-token present, repo not enrolled), explaining the
    operator's "magic cache" log chatter while delivering zero caching. Refined
    the fix recommendation toward completing FlakeHub (smallest correct change)
    or disabling it and warming the cache on main.

- type: finding
  ts: "2026-06-20T19:55:00Z"
  agent_id: "linux-claude-opus48-20260620T1955Z"
  host: "linux_mutable (interactive Claude Code CLI)"
  note: >
    Diagnosed during the v0.3.260620.8 release cycle (run 27881936382). Confirmed
    via the Actions caches API that the 2.2 GB Nix store cache is saved once per
    release tag ref with an identical key and never appears on the main default-
    branch scope, so tag-dispatched releases can never restore it (GHA ref
    isolation). Repo cache already over the 10 GB limit. Web-verified the current
    correct approach (FlakeHub Cache, or default-branch cache warming for the
    GHA-cache path). Filed fix options; paired with the release-build-monitoring
    packet so the regression cannot go silent again.

- type: completed
  ts: "2026-06-21T01:13:00Z"
  agent_id: "gemini-antigravity-worker-20260621T0113Z"
  host: "linux_mutable"
  note: >
    Option 2 (warm-cache-on-main) chosen and implemented. Dispatched Nix cache warming on
    main/linux-next default branch. Disabled FlakeHub login attempts in the Determinate installer
    by adding flakehub: false. Set save: false on release.yml Nix Cache to keep the release job
    from saving tag-scoped caches. Corrected the cache-nix-action output name from cache-hit to hit
    to allow duration assertions. Ready for verify-incremental step.

## Verify-incremental datapoint (2026-06-21T04:26 PDT / 11:26Z, meta-orch loop)

Coordinator verification of the implemented fix (commit d273daff):
- `release.yml`: `nix-installer-action` now `flakehub: false` (kills the failing
  FlakeHub-login noise) and the `Nix Cache` step has `save: false` — releases
  only RESTORE.
- New `.github/workflows/nix-cache-warm.yml` ("Warm Nix Cache") warms the cache
  on main pushes and saves it under the `refs/heads/main` default-branch scope,
  which tag-dispatched releases CAN restore (the core ref-scoping fix).
- The warm job **ran green on main at 2026-06-21T07:42:06Z** (triggered by the
  v0.3.260621.1 VERSION-bump push 77de76ba).
- **v0.3.260621.1 was the first post-fix release but ran concurrently with / just
  before the warm job finished, so it still paid the full ~no-restore cost**
  (build ~23min, FlakeHub-login noise now gone). This is expected, not a fix
  failure: the warm cache only became available at 07:42Z.
- **Next action for verify-incremental:** the NEXT release (now that main's cache
  is warmed) is the real before/after datapoint — its `nix build` step should
  restore the cross-GCC + crate closure and drop substantially vs v0.3.260621.1.
  Capture the timing per order 65 monitoring.
