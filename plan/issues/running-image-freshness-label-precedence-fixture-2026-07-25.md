# Running-image freshness stale-tag precedence failure

- **Date**: 2026-07-25
- **Classification**: enhancement
- **Status**: completed
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

## Resolution

`scripts/check-running-image-freshness.sh` now evaluates positive canonical-tag
evidence before label-only identity: the expected tag is current, a different
canonical 64-hex tag is stale even when the image inherits a source-digest
label, and a source-digest label without canonical-tag evidence remains
indeterminate. The fixture's case 5 and case 6 controls were not weakened.

## Verification

Completed on `linux-next` at
`d7b9ef93ea0b85b9bb5d9b4191326c540edbc51b` on
`macuahuitl.ayahuitlcalpan.com`:

- `scripts/test-running-image-freshness.sh`: PASS, all six cases; printed
  `PASS: running-image freshness gate fixture (order 422)`.
- `scripts/run-litmus-test.sh git-mirror-service --phase post-build --compact`:
  PASS, `litmus:running-image-freshness` completed 4/4 steps; summary `1 PASS`,
  `0 FAIL`, `18 SKIP`, `100% (1/1 executed)`.
- `bash -n scripts/check-running-image-freshness.sh scripts/test-running-image-freshness.sh`:
  PASS.
- `git diff --check`: PASS.

Verification isolation note: the direct fixture and litmus wrapper share the
intentional container name `tillandsias-git-freshness-fixture`; running them in
parallel makes their cleanup traps interfere and yields false failures. The
independent coordinator rerun executed them sequentially and reproduced the
PASS results above.

Observed remote sibling heads: `main` `e57b6a3d`, `linux-next` `d7b9ef93`,
`windows-next` `91ab1f8f`, and `osx-next` `25eb3b2a`. No commit or push was made
per operator instruction.
