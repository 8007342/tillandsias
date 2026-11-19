# Proposal — stale work refs are defects

@trace order:2100-vkpg, order:2101-b4pf, order:2102-9gyk, order:2103-pxq4

## Why

The land queue (`scripts/land-queue.sh`, order 1316-bnzt) lands non-draft PRs
in number order. It skipped drafts without a word, and a work ref with no PR
never entered it at all. The 2026-11-17 audit
(`plan/issues/abandoned-work-audit-2026-11-17.md`) found:

- 1462 branches on GitHub. 1344 of them were dead: 1307 merged by ancestry, 35
  merged by patch-id, and 2 had no unique patch. All 1344 were deleted, with
  their SHAs recorded.
- 84 refs held work that never landed: 173 commits, about 80 agent-hours
  estimated from commit timestamps. 18 were drafts (#196 to #1064, 220 to 4900
  commits behind). 21 were work refs that never got a PR. 37 were salvage or
  stash refs that were never replayed. 7 were refs whose packet was closed by
  a different landing.
- 202 packets still marked ready, and 65 marked in_progress, whose work ref had
  already landed by ancestry.

## What changes

1. The land queue prints `advisory:land-queue:ignored-draft:#N:<ref>` for every
   draft it skips (done in 2100-vkpg).
2. A stale-work guard, `scripts/lua/check-stale-work-refs.lua`, lists draft PRs
   with no unexpired hold and PR-less work refs older than N=5 days that carry
   unlanded commits. `--strict` exits non-zero (2101-b4pf).
3. The coordinator status carries a daily `stale-work:<drafts>/<prless>` metric
   (2102-9gyk).
4. Methodology: `multi_host_development.unlanded_work_is_a_defect`. A held PR
   needs a reason and an expiry. A landing-ready ref with no PR is a defect.
5. Skill: coordinate-multihost-work lists stale drafts and refs on each pass
   and acts on them.

## Why N = 5 days

The longest legitimate hold seen in the audit was a cross-host evidence wait of
about 3 days (#196 was held for a Mac run in September). 5 days covers that
plus a weekend, while catching a stranded ref within one working week. 3 days
would flag weekend holds; 7 would let a week of work go stale.
