# Freshness audit: cheatsheet staleness option order produced a false-clean result

- Date: 2026-07-30
- Class: optimization
- Status: completed
- Auditor: `forge-tillandsias-codex-20260730T1903Z`
- Component: `scripts/check-cheatsheet-staleness.sh`
- Disposition: updated

## Observation

The standing freshness inventory selected `scripts/check-cheatsheet-staleness.sh`
as its top stale component. Running the documented command
`scripts/check-cheatsheet-staleness.sh --check-urls` printed:

```text
Checking cheatsheets for staleness (> --check-urls days)...
All cheatsheets are up to date (≤ --check-urls days).
```

and exited 0. The script initialized `STALENESS_DAYS` from the first raw
argument before parsing options, so an option in position one became the
numeric threshold. Bash then treated the malformed comparison as false and
the audit silently reported a clean corpus.

## Root cause and impact

Argument defaults and option parsing were coupled. `--check-urls` without a
preceding `--days N` disabled age detection instead of enabling URL checks.
This breaks the cheatsheet freshness signal and can let outdated operational
knowledge escape the advisory scan.

Verification also exposed a second defect in the same component: the extractor
matched the documented `**Last updated:** YYYY-MM-DD` line, then expected the
space to occur before the closing `**`. It therefore reduced every correctly
formatted date to an empty string and reported `MISSING_DATE` instead of its
age.

## Closure

The audit updated the script in the same cycle:

- default days are initialized independently to 90;
- `--days` requires a non-negative integer and exits 2 otherwise;
- unknown options fail with exit 2 instead of being ignored; and
- the documented bold `Last updated` grammar is parsed into its ISO date; and
- the freshness stamp records the `updated` disposition.

Verifiable closure:

1. `--check-urls` prints a numeric 90-day threshold.
2. `--days 0` is accepted in either option order.
3. missing/non-numeric `--days` and unknown options exit 2 with a named error.
4. a fixture cheatsheet older than the selected threshold is still reported
   stale with exit 1.

## Superseded 2026-08-05

The component was **obsoleted** (deleted) by the 2026-08-05 freshness audit.
Even after the option-parser fix, the extractor still measured the
`**Last updated:**` prose line that the corpus had abandoned for `last_verified:`
frontmatter — 215/217 source cheatsheets carried frontmatter only — and the
stamp on line 3 self-attested "ran clean (exit 0, all cheatsheets <=90d)"
against the 2-file image dir. Per the operator's 2026-08-01 "fix or delete"
direction (owned by packet `cheatsheet-provenance-make-the-validator-honest-then-sign-a-manifest`,
order 588-8mh8), the script was deleted; the trace indexes were regenerated in
the same commit. Staleness now belongs to the source-layer frontmatter tooling
(`scripts/fetch-cheatsheet-source.sh --max-age-days`, policy-crate
`check-cheatsheet-sources`). See
`plan/issues/freshness-cheatsheet-staleness-script-obsoleted-2026-08-05.md`.
