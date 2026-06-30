# Methodology: Concurrent-Integration Content Duplication (skill + process fix)

**Status:** `ready`
**Owner:** linux
**Date:** 2026-06-28
**Kind:** analysis + enhancement (methodology/skills)
**Trace:** `methodology/distributed-work.yaml`, `skills/advance-work-from-plan`, `skills/merge-to-main-and-release`, `methodology/multi-host-development.yaml`

## Incident

origin/linux-next broke with `E0428` (two definitions of
`enclave_no_proxy_includes_vault_service_dns` and
`build_proxy_neutralize_vars_cover_lower_and_upper_case`). All agents are
instances of the same loop running the shared `/meta-orchestration` +
`/advance-work-from-plan` skills against the shared `plan/`, so this is OUR
process failing — not a foreign branch.

## Root Cause (evidence)

```
git log -S "fn enclave_no_proxy_includes_vault_service_dns" -- .../main.rs
  ac44771a fix(test): remove duplicate ...           # the hotfix
  6dbca259 fix(vault): add vault service DNS ...      # DUPLICATE of cb9def48 (new hash)
  cb9def48 fix(vault): add vault service DNS ...      # the original
```

`cb9def48` (the order-119 commit) re-entered linux-next a SECOND time as
`6dbca259` — same logical change, different hash — and merge `bf55712c`
("Merge origin/windows-next and origin/osx-next into linux-next") applied both,
adding the test block twice. Two compounding methodology gaps:

1. **Rebase ⨉ merge mixing.** `advance-work-from-plan §6` tells agents to
   `git rebase origin/<branch>` on non-ff (rewrites hashes), while the merge /
   multihost skills use real merge commits across `main` ⨯ `linux-next` ⨯
   `osx-next` ⨯ `windows-next`. When a rebased/cherry-picked copy of a commit
   later arrives via a cross-branch merge, git cannot dedupe it (hashes differ),
   so identical content is applied twice → duplicate definitions / silent drift.
2. **No post-merge/rebase build verification before push.** The agent that
   pushed `bf55712c` resolved conflicts but did not re-run `./build.sh --check`
   on the merged tree before pushing, so a tree that compiled on neither parent
   shipped to origin and broke every subsequent puller.

## Fixes (verifiable)

### Fix A — re-verify after every integration, before push (skill rule)
Amend `advance-work-from-plan §6` and `merge-to-main-and-release` /
`multihost-orchestration`: **after any `git rebase`/`git merge`, run
`./build.sh --check` (and the instant litmus suite) on the resulting tree BEFORE
`git push`.** A non-green post-integration tree must NOT be pushed; resolve or
abort. Pinned by a process-litmus that greps the skill text for this rule.

### Fix B — duplicate-symbol guard (fast, fail-loud)
Add `litmus:no-duplicate-rust-item-defs` (instant phase): scan each crate's
sources for duplicate `fn <name>(` / `#[test] fn <name>` within the same module
scope and exit non-zero on a collision. This catches the exact E0428 class in
milliseconds, independent of a full build, and runs in the pre-push gate.

### Fix C — one integration strategy (kill the rebase⨉merge ambiguity)
Decide and document a single cross-branch integration model in
`methodology/multi-host-development.yaml`:
- Option 1: **merge-only** — agents never `git rebase` shared branches; non-ff is
  resolved by `git pull --no-rebase` (merge) so a commit keeps ONE hash forever.
- Option 2: **rebase-only with no cross-branch merges** — platform branches only
  ever fast-forward from `main`; integration is PR→main, never branch⨯branch merge.
Pick one; update `advance-work-from-plan §6` and the multihost skill to match so
the same logical commit can never exist under two hashes on the trunk.

## Exit Criteria

- `advance-work-from-plan` + merge/multihost skills require post-integration
  `./build.sh --check` before push (text + process-litmus).
- `litmus:no-duplicate-rust-item-defs` added, pinned, green on current tree.
- `methodology/multi-host-development.yaml` declares ONE integration strategy;
  the rebase⨉merge contradiction is removed from the skills.

## Related

- `plan/issues/agent-concurrency-collisions-2026-06-20.md` (ledger-node claim — the
  *ledger* analogue of this *code* collision; this packet extends it to source files)
- `feedback_agentic_git_attribution` (agent memory) — agentic git discipline
- `coord-osx-vz-fmt-drift-2026-06-28.md` (the osx-next divergence — same family)
