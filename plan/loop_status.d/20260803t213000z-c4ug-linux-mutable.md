## Cycle 2026-08-03T21:30Z (linux_mutable — v0.5 cross-platform readiness)

Prepared the Windows and macOS hosts for their v0.5 validation cycles, and
cleared two release blockers this project had created for itself.

**Cloud minutes — the purge was incomplete and I did not notice at the time.**
The 2026-08-03 Actions removal only ever touched `linux-next`. `ci.yml` was still
live on `windows-next` and `osx-next`, and `nix-cache-warm.yml` still sat on
`main` — the DEFAULT branch, which is the only branch GitHub schedules cron from.
It fired 2026-08-02T06:35, after the purge. Siblings were cleaned by
fast-forwarding them to `linux-next` (both 0 ahead, verified ancestors); `main`
by PR #86. All four branches now carry `release.yml` alone, and no push- or
schedule-triggered run has fired since 2026-08-02T04:50.

**`main` was frozen, not protected.** Branch protection required three status
contexts that were the verbatim job names of the deleted `ci.yml`, with
`enforce_admins: true` — so no `linux-next → main` PR could ever become
mergeable. Operator chose to clear the contexts; the PR requirement and admin
enforcement are unchanged, and the prior state is recorded for reversal. Proven
by PR #86 merging CLEAN with 0 checks.

**The local gate is already earning its keep.** `./build.sh --check` refused with
`clippy::overly_complex_bool_expr`: `query_packets` carried
`.filter(|_| limit == 0 || true)`, landed on `linux-next` in the query-overlay
work on the same day push CI was removed. Fixed. First concrete instance of the
gate being the only thing between an agent and a broken trunk — and it was found
by an agent that happened to run it, not by one the loop instructed to.

**First real ledger compaction.** 28 fragments folded into the base with 120
comment lines preserved, 535 packets preserved, and a `plan/index.yaml` diff of
1021 added and ZERO removed lines. Corrected the skill and methodology, which
both still told agents compaction refuses by design.

**Filed:** 598-yhu5 (windows bundle, 6 scoped items), 598-kibt (macos bundle, 6),
598-c4ug (worker skills still teach in-place ledger edits — p0, two cycles are
about to follow them), 598-znuv (loop skill never names the local gate),
597-fmm2 / 597-pr4x (no disk-headroom preflight; the order-281 self-heal destroys
the git mirror and forge cache, and a full disk produces the signature that
triggers it).

**Open:** `litmus:opencode-prompt-e2e-shape` step 3 still red (FORGE_EXIT=125).
Host is at 96% disk, which is a live candidate but not yet established as the
cause. BigPickie's crash trail on `linux-next-debug` (Bun v1.3.14 as PID 1,
`pids.max=512`) is the other open thread.
