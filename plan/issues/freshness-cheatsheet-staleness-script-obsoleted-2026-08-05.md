# Freshness audit: check-cheatsheet-staleness.sh obsoleted (operator "fix or delete" executed)

- Date: 2026-08-05
- Class: freshness
- Status: completed
- Auditor: `forge-opencode-20260805t021300z`
- Component: `scripts/check-cheatsheet-staleness.sh`
- Disposition: obsoleted (deleted, same-commit dependents removed)
- Owning packet: `cheatsheet-provenance-make-the-validator-honest-then-sign-a-manifest` (order 588-8mh8)

## Observation

The standing freshness inventory selected `scripts/check-cheatsheet-staleness.sh`
as the top stale component (last stamped 2026-08-01). Re-verification:

- Standalone run against the default `./cheatsheets` dir: PASS (all ≤ 90 days) —
  but only 2 files carry the `**Last updated:**` prose line the script extracts.
- With `TILLANDSIAS_CHEATSHEETS` unset it flagged 217 of 217 source `.md` files
  as `MISSING_DATE`: the corpus abandoned the prose line for `last_verified:`
  YAML frontmatter (215/215 files, `cheatsheets/TEMPLATE.md`, and the
  `REGEN_INDEX_HEADER` contract at `crates/tillandsias-policy/src/main.rs:3946`).
- The script's own freshness stamp (line 3, dated 2026-08-01) asserted
  "verdict=refreshed ... re-ran clean (exit 0, all cheatsheets <=90d)" — a
  self-attestation produced against the 2-file image dir. This is precisely the
  "checker measures a field that no longer exists, then self-attests clean"
  pattern the operator flagged on 2026-08-01 (plan/index.yaml:28746).

The operator's direction for this exact script was explicit: **"fix or delete"**.
A "fix" would re-implement frontmatter extraction that the policy crate's
source-layer tooling already performs robustly (`fetch-cheatsheet-source.sh
--max-age-days`, `check-cheatsheet-sources`) — a repaired wheel — and the script
had no wired callers in build.sh/scripts/.github. Discard-over-repair applied:
**deleted**.

## Closure

- `git rm scripts/check-cheatsheet-staleness.sh` (the only live reference to the
  script was its own `@trace` annotations; no caller existed).
- Regenerated trace indexes (`scripts/generate-traces.sh`) in the same commit —
  this also repaired an independent staleness: the 605-u9g5 commit's new
  `@trace` annotations (`images/default/config-overlay/codex/register-experts.sh`,
  `scripts/test-codex-mcp-registration.sh`) and Containerfile line shifts had
  never been indexed, because `./build.sh --check` does not regenerate traces.
- `cheatsheets/runtime/cheatsheet-shortcomings.md:68` reworded to record the
  obsoletion and the superseding mechanism.
- Superseded note appended to
  `plan/issues/optimization/cheatsheet-staleness-option-parser-2026-07-30.md`.
- `progress` event recorded on packet 588-8mh8 (partial slice; the packet
  remains `ready` — its exit criteria are untouched).

## Superseding mechanism

Staleness now belongs to the source-layer frontmatter tooling
(`scripts/fetch-cheatsheet-source.sh --max-age-days`, policy-crate
`check-cheatsheet-sources`); making `last_verified` drive a real, honest signal
— signed manifest gating the image bake, status computed from `last_verified` —
is the remaining work of packet 588-8mh8.

## Verifiable closure

1. `git ls-files scripts/check-cheatsheet-staleness.sh` is empty.
2. `scripts/generate-traces.sh --check` exits 0 (indexes current).
3. `rg check-cheatsheet-staleness` in live docs/scripts returns only historical
   ledger/archive references.
4. `./build.sh --check` exit 0.
