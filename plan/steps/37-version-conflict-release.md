# Step 37 — Resolve v0.3.0 VERSION conflict & cut the release

- **Status**: needs_clarification (operator decision)
- **Owner host**: release / operator
- **Branch**: main (release) ← linux-next
- **Depends on**: []
- **Specs**: ci-release, versioning

## Goal

The v0.3.0 release never shipped. Commit `71bd4d2c` (operator, 2026-06-03) bumped `VERSION`
on `linux-next` to `0.3.260603.1` while `main` is at `0.2.260603.1`, so PR #15
(linux-next → main) is `mergeable_state: dirty` (3-way conflict in `VERSION` + crate
versions). No tag, no `release.yml` dispatch. See the 18:07Z escalation in
`plan/issues/multi-host-integration-loop-2026-05-24.md`.

## Clarification needed (operator)

Which resolution path? **Recommended default: Option 1.**

1. **(Recommended) Embrace the 0.3.x series on `main`.** Merge `linux-next` → `main` locally
   accepting `VERSION=0.3.x`, push `main`, then `gh release create v0.3.260603.1` (creates the
   tag) and/or `gh workflow run release.yml --ref main`. Lowest risk; matches the intentional
   major-series transition. (Tag push / workflow dispatch must run from a host with `gh` and
   `actions: write` — the container proxy blocked these in prior cycles.)
2. **Rebase `linux-next` onto `main`**, resolving `VERSION` by keeping 0.3.x, force-push.
   ⚠ Rewrites `linux-next` history — must coordinate with osx-next/windows-next hosts first.
3. **Update the release skill's version formula** to compute `0.3.YYMMDD.N` and re-run
   `skills/merge-to-main-and-release`.

## Tasks

- [ ] Operator selects a path (default: 1).
- [ ] Resolve `VERSION`/crate-version conflict and merge/close PR #15.
- [ ] Create tag `v0.3.x` and trigger `release.yml`; read back the published GitHub Release.
- [ ] If Option 3, update `skills/merge-to-main-and-release/SKILL.md` Step 1 formula.

## Acceptance evidence

- `main` carries the 0.3.x VERSION; PR #15 merged/closed; tag `v0.3.x` exists on GitHub;
  release assets (linux binary, installer, SHA256SUMS, Cosign bundles) published and
  read back.

## Note

This is the top live blocker but is **operator-gated** and out of autonomous scope (tag
push + workflow dispatch require credentials the in-container agents lack). Surfaced as a
plan item so it is not lost; the integration-loop ledger holds the running escalation.
