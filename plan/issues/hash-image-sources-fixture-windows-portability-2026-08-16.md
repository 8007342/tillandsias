# test-hash-image-sources.sh is not windows-portable: autocrlf breaks the clone-location check, fileMode voids the exec-bit scenario

- classification: enhancement
- filed: 2026-08-16 (windows, meta-orchestration cycle 5)
- status: open
- related: plan/issues/windows-red-meta-orchestration-litmus-2026-08-16.md
  (item 2, `litmus:meta-orchestration-dirty-tree-safety` STEP 5/5)

## Observation

Cycle 4 recorded the step as a TIMEOUT-at-10s in the step-budget-resize
class. Resizing exposed that the timeout was MASKING two real platform
interactions (measured 2026-08-16, windows, fixture standalone):

1. With the host's `core.autocrlf=true` (this machine's global config), the
   fixture fails at `FAIL: forge hash depends on checkout location` in
   ~11.5s: the fixture writes LF files into `$repo`, but the `git clone`
   checks out CRLF working-tree bytes, so `scripts/hash-image-sources.sh`
   hashes different bytes in the two locations.
2. With autocrlf forced off (`GIT_CONFIG_GLOBAL` pointing at
   `core.autocrlf=false`), it proceeds to `FAIL: executable-bit change did
   not invalidate forge hash` in ~16s: git-for-windows sets
   `core.fileMode=false` on NTFS, so the fixture's `chmod +x` never reaches
   the index and the hash correctly does not change — the SCENARIO is
   unfalsifiable on this platform, not the hasher wrong.

The step budget was ALSO undersized (10s < 11.5-16s of git ops); cycle 5
resized it to 90s so the step now reports its real verdict instead of
TIMEOUT, and left the step red on windows for the reasons above.

## Questions the fix must answer

- Is the forge image built from working-tree bytes? If yes, hash divergence
  under autocrlf is TRUTH (different bytes -> different image) and the
  fixture should pin the repo's line-ending config instead of comparing
  cross-config checkouts. If the image build normalizes, the hasher should
  hash git-normalized content (`git ls-files -s` object ids) rather than
  working-tree bytes.
- The exec-bit scenario needs a `git config core.fileMode` probe: skip (with
  a loud skip verdict) where false, rather than asserting a mutation the
  platform cannot record.

## Smallest next action

In scripts/test-hash-image-sources.sh: set `core.autocrlf=false` (and
`core.symlinks` explicitly) in the fixture repos' local config at init, and
gate the chmod scenario on `core.fileMode=true`. Decide the hasher question
above with the fixture's owner before changing scripts/hash-image-sources.sh
itself.

## Decision (2026-08-16)

- who: The Tlatoāni (operator), attended session on windows/Yolanda,
  2026-08-16
- what: **hash-image-sources hashes GIT-NORMALIZED content, not
  working-tree bytes.** The "Questions the fix must answer" hasher question
  above is thereby ruled: the hash derives from git-normalized content
  (e.g. `git ls-files -s` object ids), so two clones of the same commit
  hash identically regardless of `core.autocrlf` or checkout location.
- implementation: packet `hash-image-sources-git-normalized` (order
  776-cm74, pickup_role any), filed
  plan/index.d/20260816t211000z-776-cm74-windows.yaml. The exec-bit
  scenario gating on `core.fileMode` remains part of that packet's scope.
