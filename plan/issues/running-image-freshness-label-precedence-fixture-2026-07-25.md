# Running-image freshness stale-tag precedence failure

- **Date**: 2026-07-25
- **Classification**: enhancement
- **Status**: ready
- **Desired release**: v0.4
- **Order**: 488
- **Discovered by**: `/build-install-and-smoke-test-e2e (linux)`

## Reproduction

Run `scripts/test-running-image-freshness.sh` after building the git image.
Case 3 creates a distinct image tagged with the canonical-looking stale hash
`0000...deadbeef`, starts it, and expects exit 1. The gate instead exits 0:

```text
indeterminate: tillandsias-git-freshness-fixture carries a source-digest label
PASS: running image freshness (checked 1 container(s), 1 indeterminate, ...)
```

Evidence:
`target/build-install-smoke-e2e/20260725T045500Z/01-build-install.log` in the
`litmus:running-image-freshness` post-build result.

## Root cause

The synthetic child image inherits the current base image's
`io.tillandsias.image.source-digest` label. The gate checks for any source label
before checking for a different canonical 64-hex tag, so the inherited label
masks stronger positive stale evidence.

## Verifiable repair

Define explicit evidence precedence: expected canonical tag is current; a
different canonical 64-hex tag is stale; label-only identity is indeterminate.
Keep case 5 proving an unidentified image is not falsely called stale and case
6 proving strict mode escalates indeterminate.
