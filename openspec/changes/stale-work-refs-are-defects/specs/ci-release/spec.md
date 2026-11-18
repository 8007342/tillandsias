## ADDED Requirements

### Requirement: Work the land queue will not land is reported, not skipped silently

The land queue SHALL print one `advisory:land-queue:ignored-draft:#<n>:<ref>` line for every open draft PR it passes over, on every run, including a run that lands nothing. A stale-work guard SHALL list every open draft PR without an unexpired hold (a reason and an expiry date at most 5 days out) and every `work/*` ref with no open PR that is older than 5 days and carries commits not on the trunk by ancestry or patch-id. In `--strict` mode the guard SHALL exit non-zero when that list is not empty. The coordinator status SHALL carry the daily count as `stale-work:<drafts>/<prless>`.

#### Scenario: a drafts-only queue names its drafts

- **WHEN** the open PR list holds only drafts #42 and #196
- **THEN** the queue prints an ignored-draft advisory for each of them and exits 0 with `ok:land-queue:0`

#### Scenario: a PR-less ref with unlanded commits is stale after 5 days

- **WHEN** `work/x` has no PR, its newest commit is 6 days old, and `git cherry` against the trunk shows a `+` commit
- **THEN** the guard lists `work/x`, and `--strict` exits 1

#### Scenario: a landed ref is not stale

- **WHEN** `work/y` has no PR and is an ancestor of the trunk
- **THEN** the guard does not list it
