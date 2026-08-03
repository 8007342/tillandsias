# gate-stamp compute() hashed THROUGH symlinks — stamp unrecordable, every macOS push refused

- **Date:** 2026-08-03
- **Host:** macOS (Tlatoanis-MacBook-Air, Darwin 25.6.0, Apple Silicon)
- **Branch:** osx-next @ 9e291df3 (first macOS cycle after the 2026-08-03 Actions purge)
- **Related packets:** 599-w5jd (release-gates-moved-to-local-hardware, shipped the stamp),
  599-4wzr (hooks-shipped-but-never-installed-audit — this file is the macOS report),
  598-kibt (macos-v05-validation-bundle, found during M1)
- **Status:** FIXED in this cycle (scripts/gate-stamp.sh), fix carried on osx-next

## What happened

First `./build.sh --check` on this host after hook installation ended with
`Could not record gate stamp — pre-push may ask you to re-run --check` even
though the gate itself was GREEN. `bash scripts/gate-stamp.sh write` reproduced:
`stale:cannot-write-stamp`, exit 1. Because the pre-push hook refuses on
`stale:never-run`, the enforcement chain 599-w5jd shipped was a hard NO-PUSH on
macOS: a green gate could never produce a pushable state without `--no-verify` —
the exact bypass the design set out to make unnecessary.

## Root cause

`compute()` piped every `git ls-files` entry into `xargs -0 -r sha256sum`. The
repo COMMITS symlinks-to-directories — the per-runtime skill links
(`.claude/skills/<name>`, `.codex/skills/<name>`, `.gemini/…`, `.github/…`,
`.opencode/…` → `../../skills/<name>`, ~44 of them). `sha256sum` follows the
link, hits the directory, exits 1 (`Is a directory`), `set -o pipefail`
propagates through the function, and `write` never records the stamp.

The 11-step litmus and the by-hand verification recorded in 599-w5jd ran in a
throwaway fixture repo with no symlink-to-directory entries, so the defect was
structurally invisible there — the same "verified where it was written, not
where it runs" class the ledger keeps naming (cf. litmus:github-actions-budget
residual in 598-u97y).

## Fix

`compute()` now folds symlinks in as `link:<path> -> <target>` lines — git's own
content model for links (retargeting a link changes the stamp; its target's
bytes are counted once, under the target's path) — and batches only regular
files through `sha256sum`. Verified on macOS end-to-end: `write` →
`ok:gate-fresh` → edit a file → `stale:tree-changed-since-gate` → revert →
`ok:gate-fresh`, ~0.5s per compute over ~4600 files.

## Residual for Linux pickup

- `compute()` before this fix should fail the same way on ANY checkout carrying
  the committed skill symlinks — including linux-mutable. If pushes from Linux
  succeeded with a recorded stamp after 9e63de0e, ask how: either the failure
  mode differed there (worth understanding) or stamps were being written by an
  older algorithm and `verify` was comparing stale-vs-stale.
- litmus:release-gates-run-locally's stamp fixture should gain a
  symlink-to-directory negative control so the fixture repo can see this class.
