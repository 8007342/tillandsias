## Cycle 2026-08-14T02:22Z — linux_mutable (meta-orchestration full mode, linux-next)

COORDINATOR: merged origin/windows-next (69dd87c8) — clean. Brings 723-54zj (probe whether a PTY session is blocked reading its terminal).

DRAINED 601-462g — the audit ran, not just its first instance. Enumeration in plan/issues/runbook-external-precondition-audit-2026-08-14.md: every skill step gating on an external command, with what that command returns when the thing it asks about is ABSENT.

The gh list subcommands are the dangerous family — exit 0 on an empty result set, and --jq '.[0].x' renders that emptiness as the literal string null, so a bare exit test AND a bare emptiness test both pass. merge-to-main-and-release step 2 held the THIRD instance in one file: with no open PR the emptiness test was FALSE, gh pr create never ran, and the runbook announced PR #null before walking into step 3 to merge a pull request that does not exist. Fixed with scripts/resolve-open-pr.sh (fixture 5/5), deliberately a twin of resolve-release-run.sh so the pair reads as one pattern. Step 1's two "# MUST be ..." comments became assertions — a comment beside git status --short is not a gate.

The podman and wsl sites are all SOUND for a structural reason worth naming: they assert a positive fact, or an emptiness that IS the requirement. The gh sites were unsound because they extracted a value and then trusted it. Extracting a value is where this class lives.

FILED 731-d89b: both Windows-authored resolvers landed at mode 100644, so the runbook's direct invocation of resolve-release-run.sh was a permission error on Linux. Found only because the new litmus asserts test -x.

CAUGHT BY A SIBLING'S GUARD, worth recording: this cycle's first loop-status write was REFUSED by 719-kgr5 (merged from windows two cycles ago) because the --ts I passed ran 1679s ahead of the host clock — I had been writing nominal cycle timestamps rather than reading the clock. The guard is right and the habit was wrong; this entry carries the real clock. The same nominal habit is visible in this cycle's ledger fragment timestamps, which no guard checks.

litmus:release-runbook-external-preconditions-shape 4/4, bound to ci-release. Gate green.
