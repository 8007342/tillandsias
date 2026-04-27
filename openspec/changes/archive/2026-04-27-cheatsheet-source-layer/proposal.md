## Why

Tillandsias's cheatsheet provenance discipline ALREADY mandates citing
high-authority source URLs. But there's no enforcement that the cited
URL was actually fetched at authoring time vs. plausibly invented.
The recent `cheatsheets/runtime/local-inference.md` was a textbook
example: three plausible URLs cited, none actually fetched, and one
of the documented endpoints (`/api/embeddings`) had been superseded
upstream (`/api/embed` is current). The cheatsheet's "blessing" was
hollow. This change introduces a verbatim-source layer that makes
citation provenance physically verifiable: every cited URL has a
content-hashed, license-checked, locally-stored copy that any
maintainer can re-read offline.

The user phrased it: "the cheatsheet 'blessing' of the authoritative
url provenance means it was web fetched (and optionally summarized)
from it... a FULL SPEC layer below the cheatsheets which SHALL
DOWNLOAD the api authoritative document VERBATIM in READABLE and
PARSABLE FORMAT (single page HTML wherever available) and organized
in a shared readable NOT HOT PATH."

## What Changes

- **NEW** sibling tree `cheatsheet-sources/` at repo root (cold path
  per the upcoming forge-hot-cold-split; never tmpfs, never baked into
  the forge image). Structure: `cheatsheet-sources/<host>/<path>/<basename>.<ext>`
  — deterministic from URL, mirror of the host + path layout. LFS-tracked
  for verbatim payloads; plain YAML sidecar `<file>.meta.yaml` carries
  SHA-256, fetch-date, license, redistribution status, http_status,
  cited_by list.

- **NEW** central `cheatsheet-sources/INDEX.json` regenerated from
  sidecars (the same way `cheatsheets/INDEX.md` is regenerated from
  frontmatter). Auto-generated `cheatsheet-sources/ATTRIBUTION.md`
  rolls up per-publisher attribution for downstream redistribution.

- **NEW** `cheatsheet-sources/license-allowlist.toml` — known-good
  source domains + their licenses + redistribution status. Initial
  bundled-OK list: rfc-editor.org, datatracker.ietf.org, w3.org,
  whatwg.org, developer.mozilla.org, owasp.org, kernel.org,
  docs.python.org, doc.rust-lang.org, raw.githubusercontent.com (per
  vendor). Initial do-not-bundle (link-only, fetched copy
  `.gitignore`-d): docs.aws.amazon.com, docs.microsoft.com,
  cloud.google.com.

- **NEW** tooling (`scripts/`):
  - `fetch-cheatsheet-source.sh <URL> [--cite cheatsheets/<path>]` —
    the fetcher.
  - `regenerate-source-index.sh` (+ `--check`).
  - `check-cheatsheet-sources.sh` — wired into `openspec validate` and
    pre-commit.
  - `refresh-cheatsheet-sources.sh [--max-age-days N]` — drift detection.
  - `audit-cheatsheet-sources.sh` — CSV migration triage.

- **MODIFIED** every cheatsheet's `## Provenance` section gains a
  `local: cheatsheet-sources/...` line per cited URL. Plus the
  fetch-date and license. CI fails if any cheatsheet's URL has no
  corresponding INDEX.json entry, OR if a `local:` path doesn't
  resolve (or doesn't have a `redistribution: do-not-bundle` sidecar).

- **MODIFIED** `agent-cheatsheets` capability spec: requirement that
  every Provenance URL MUST have a verbatim local copy or an explicit
  `do-not-bundle` flag. The cheatsheet template adds the local-path
  field.

- **MODIFIED** `cheatsheets/INDEX.md` regen script appends
  `[verified: <sha256-prefix>]` to each line so agents (read-only
  view) see the verbatim-backing marker without seeing the bytes.

- **MODIFIED** forge container behavior: opt-in
  `forge.mount_source_layer = true` config flag bind-mounts
  `cheatsheet-sources/` read-only at `/opt/cheatsheet-sources/` for
  cheatsheet-author workflows. Off by default; agents NEVER see the
  cold layer in normal operation. Logged via `accountability` channel.

## Capabilities

### New Capabilities

- `cheatsheet-source-layer` — verbatim-source storage, fetcher tool,
  manifest format, license allowlist, validation invariants, hot/cold
  separation, attribution rollup.

### Modified Capabilities

- `agent-cheatsheets` — Provenance section now requires local-path
  field per cited URL; cheatsheet INDEX.md gains verified-marker
  suffix; new validator hook.

## Impact

- **Repo**: new `cheatsheet-sources/` tree (LFS), new
  `scripts/fetch-*` + `regenerate-source-index.sh` +
  `check-cheatsheet-sources.sh` + `refresh-*` + `audit-*`. Possibly
  several MB of bundled HTML/markdown/RFC text on initial bulk fetch.

- **CI**: new validator hook in `openspec validate`, new pre-commit
  rule. Fast (no network — just SHA + index check).

- **Tray**: optional `forge.mount_source_layer` config flag; one
  additional bind-mount when on. Off by default — zero overhead.

- **Agent surface (forge)**: zero change in default mode. With opt-in
  flag, agents can `cat /opt/cheatsheet-sources/<host>/<path>` to
  re-verify a citation.

- **Operators**: a new ~2-hour maintenance task at first rollout
  (bulk-fetch the existing ~80 cheatsheets' citations). Subsequent
  cheatsheet authoring gets a one-line workflow change:
  `scripts/fetch-cheatsheet-source.sh <URL> --cite cheatsheets/<path>`
  before committing.

- **Downstream redistributors**: `cheatsheet-sources/ATTRIBUTION.md`
  is the single artefact to honour for license attribution.

## Sources of Truth

- `cheatsheets/runtime/cheatsheet-frontmatter-spec.md` — the
  cheatsheet frontmatter contract this change extends with a
  `verified_local:` field.
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — the
  hot/cold path taxonomy this change pins `cheatsheet-sources/` to.
- `docs/strategy/cheatsheet-source-layer-plan.md` — the Opus design
  doc this proposal compresses into the proposal/design/spec/tasks
  shape.
- `docs/strategy/forge-hot-cold-split-plan.md` — the upcoming hot/cold
  split that this change is the cold-path counterpart of.
