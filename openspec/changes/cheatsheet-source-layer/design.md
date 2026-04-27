# Design — cheatsheet-source-layer

## Context

Cheatsheets at `cheatsheets/` are the agent's hot-path knowledge. Each must
have YAML frontmatter (`tags`, `since`, `last_verified`, `sources`,
`authority`, `status`) plus a `## Provenance` section listing high-authority
source URLs. The discipline already exists; the failure mode is that
authoring agents (including this one) have written cheatsheets citing
plausible URLs WITHOUT actually fetching them. `cheatsheets/runtime/local-inference.md`
was the canonical case: three URLs cited, none fetched, one of the
documented endpoints (`/api/embeddings`) had been superseded upstream
(`/api/embed` is current).

This change introduces a verbatim-source layer beneath the cheatsheets that
makes citation provenance physically verifiable. Every cited URL has a
content-hashed, license-checked, locally-stored copy. CI verifies both
sides exist. The cold-path layer (per the upcoming `forge-hot-cold-split`)
sits at `cheatsheet-sources/` — host disk only, never tmpfs, never baked
into the forge image.

## Goals / Non-Goals

**Goals:**
- Every authoritative URL cited in a cheatsheet's `## Provenance` SHALL have
  a verbatim local copy on host disk.
- The cheatsheet's `## Provenance` SHALL carry the `local:` path next to
  the URL so a maintainer can `cat` the file to re-verify offline.
- License vetting: bundled bytes SHALL come from a known-good
  freely-distributable source. Off-allowlist domains pass through manual
  review.
- Auto-attribution: a top-level `cheatsheet-sources/ATTRIBUTION.md` (generated)
  is the single artefact a downstream redistributor reads to honour licenses.
- CI hook validates the binding (cheatsheet ↔ INDEX.json ↔ on-disk file)
  on every commit.

**Non-Goals:**
- Real-time refresh of fetched bytes. Manual refresh via
  `scripts/refresh-cheatsheet-sources.sh` is the contract.
- Fetching content the user explicitly opts out of (private docs, paywalled
  content). Off-allowlist domains require `--manual-review`.
- Replacing the existing `## Provenance` section. The change is additive.
- Schema-validating the fetched content. SHA-256 + line-count delta on
  refresh is the only correctness signal.
- Hot-path access from agents inside the forge. The verbatim layer is the
  operator's accountability proof, NOT runtime fuel.

## Decisions

### Decision 1 (Q1) — Storage as a sibling top-level `cheatsheet-sources/`

**Choice**: `cheatsheet-sources/` at repo root, sibling of `cheatsheets/`.

**Why**: Sibling-of-`cheatsheets/` makes the relationship grep-obvious.
NOT under `docs/` (that's human-curated narrative). NOT under `images/` (it
is intentionally NOT shipped into the forge image). The hot/cold split
locks this directory to COLD path: disk only, never tmpfs, never baked into
any image.

**Rejected alternatives**: `docs/cheatsheet-sources/` (mixes human narrative
with a fetched cache), `cheatsheets/sources/` (subdirectory of the hot path
implies it might be hot too), `vendor/` (Rust convention, but this isn't a
vendored Rust dep).

### Decision 2 (Q2) — LFS-track verbatim payloads, plain-track sidecars

**Choice**: `cheatsheet-sources/**/*.html` and `*.pdf` are LFS-tracked.
`*.meta.yaml` sidecars and `INDEX.json` and `ATTRIBUTION.md` are plain-tracked.
`*.norepublish` artefacts are gitignored (sidecar only is committed for
do-not-bundle sources).

**Why LFS for payloads**: HTML can be 1-5 MB per page; 60+ sources
compresses poorly in git pack files. LFS keeps the pack small.

**Why plain-track sidecars**: human-readable diffs of license/hash/date
changes when a source updates. The whole audit story depends on these
being legible.

**Why bundled-by-default**: a fresh clone produces a maintainer who can
verify everything OFFLINE, including the user's expectation that "cheatsheet
blessing means the URL was actually fetched, and the bytes are here".

### Decision 3 (Q3) — Deterministic on-disk path mirrors URL host + path

**Choice**: `cheatsheet-sources/<host>/<path-with-slashes>/<basename>.<ext>`.
Same URL → same path, always. No timestamps in the path; timestamps live
in the sidecar.

**Why**: re-fetching the same URL overwrites in place, sha256 catches drift,
the sidecar's `fetched` field bumps. Renames or moves don't accumulate
orphan files.

**GitHub blob URL rewriting**: the fetcher rewrites
`https://github.com/<owner>/<repo>/blob/<branch>/<path>` to
`https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>` BEFORE
fetching. The on-disk path uses the raw form. This avoids fetching GitHub's
HTML wrapper around the actual content.

### Decision 4 (Q4) — Stored format precedence

**Choice** (in order): single-page HTML > RFC text > Markdown > PDF.

**Why single-page HTML preferred**: directly per user request. Multi-page
documentation (where each section is its own URL) would force fetching N
pages and stitching, which loses the "one URL = one verbatim file" mapping.

**Why RFC text wins for IETF**: text is the canonical IETF form, easier to
grep, unambiguously redistributable.

**Why PDF last resort**: only when nothing else exists (W3C TR documents,
some ISO previews). Stored as-is plus `<basename>.pdf.txt` extracted via
`pdftotext` for grep-ability.

**JS-rendered SPAs** (returning empty `<body>`): flagged with `render:
js-required` in the sidecar. Resolution path: try `?print=1` / `/print/`
variants, try the project's GitHub-source mirror, last resort use the
host-chromium escape hatch (out of scope for the automated fetcher; manual
operator action only).

### Decision 5 (Q5) — Per-file YAML sidecar PLUS central INDEX.json

**Choice**: Each verbatim file has a colocated `<file>.meta.yaml` (the
authoritative metadata). A central `cheatsheet-sources/INDEX.json` is the
union of all sidecars in deterministic order, regenerated from the
sidecars by `scripts/regenerate-source-index.sh` (the same way
`cheatsheets/INDEX.md` is regenerated from frontmatter).

**Why both**: the sidecar lives next to the bytes (survives directory
moves; legible when staring at one source). The central index is the
queryable form for CI / MCP / the validator. CI's `--check` mode rejects
out-of-date INDEX.json.

**Sidecar fields** (full schema):
```yaml
url: <original URL>
canonical_url: <after redirect resolution>
fetched: <ISO 8601 UTC>
fetcher_version: 1
content_sha256: <hex>
content_length: <int>
content_type: <from server>
http_status: 200
final_redirect: <last URL in chain>
publisher: <human name>
license: <SPDX-style identifier>
license_url: <URL to license text>
redistribution: bundled | attribute-only | do-not-bundle
allowlist_match: <domain that matched the allowlist>
render: static | js-required | pdf-only
title: <document title>
cited_by:
  - cheatsheets/<path1>
  - cheatsheets/<path2>
notes: ""
```

### Decision 6 (Q6) — Cheatsheet `## Provenance` shape

**Choice**: extend the existing format with a `local:` path per source URL:

```markdown
## Provenance

- MDN "HTTP cookies" — fetched 2026-04-26, license: CC-BY-SA 2.5,
  local: `cheatsheet-sources/developer.mozilla.org/en-US/docs/Web/HTTP/Cookies.html`
  Source: <https://developer.mozilla.org/en-US/docs/Web/HTTP/Cookies>
- **Last updated:** 2026-04-26
```

**Why both URL AND local path visible**: a maintainer can `cat
cheatsheet-sources/...` to re-verify the bytes WITHOUT round-tripping the
network. The URL is for the original-source attribution and for re-fetching
when the maintainer chooses to refresh.

### Decision 7 (Q7) — License allowlist gates bundling

**Choice**: `cheatsheet-sources/license-allowlist.toml` lists known-good
domains plus their licenses + redistribution status. Initial allowlist:

| Domain | Publisher | License | Redistribution |
|---|---|---|---|
| `rfc-editor.org` | IETF / RFC Editor | IETF Trust Legal Provisions | bundled |
| `datatracker.ietf.org` | IETF | IETF Trust Legal Provisions | bundled |
| `www.w3.org` | W3C | W3C Document License (2015) | bundled |
| `whatwg.org` | WHATWG | CC-BY 4.0 | bundled |
| `developer.mozilla.org` | MDN contributors | CC-BY-SA 2.5 | bundled |
| `owasp.org` | OWASP | CC-BY-SA 4.0 | bundled |
| `www.kernel.org` | kernel.org | GPL-2.0+ | bundled |
| `docs.python.org` | Python Software Foundation | PSF | bundled |
| `doc.rust-lang.org` | The Rust Project | MIT or Apache-2.0 | bundled |
| `raw.githubusercontent.com/ollama/ollama` | Ollama project | MIT | bundled |
| `docs.aws.amazon.com` | AWS | AWS Customer Agreement | do-not-bundle |
| `learn.microsoft.com` | Microsoft | Microsoft Docs License | do-not-bundle |
| `cloud.google.com` | Google | Google Documentation License | do-not-bundle |

**Why this exact list**: the four IETF/W3C/WHATWG/MDN/OWASP rows cover ~70%
of expected citations. Vendor docs from major cloud providers go
do-not-bundle by default — we link, don't ship — to avoid license-violation
risk.

**Off-allowlist domains** require `--manual-review` flag on the fetcher.
The resulting sidecar gets `redistribution: do-not-bundle` and the file is
suffixed `.norepublish` (gitignored).

### Decision 8 (Q8) — Hot/cold integration: forge agents do NOT see verbatim by default

**Choice**: `cheatsheet-sources/` is host-side only. NOT bind-mounted into
forge containers in normal operation. The agent's view stops at the
cheatsheet's blessed summary at `/opt/cheatsheets/`. The verbatim layer is
the operator's accountability proof.

**Maintainer escalation**: opt-in `forge.mount_source_layer = true` config
flag bind-mounts `cheatsheet-sources/` read-only at `/opt/cheatsheet-sources/`
in the forge. Off by default; specifically for cheatsheet-author
workflows where the agent needs to grep verbatim sources to write a new
cheatsheet. Logged via `accountability` channel.

**Why default off**: keeps the forge's footprint small (forges already
require ~1.4 GB committed RAM per the hot/cold plan; adding cheatsheet-sources
adds nothing to RAM but adds a bind mount, container start time, and
discoverability surface that 99% of agent workflows don't need).

**`[verified: <sha256-prefix>]` markers**: `cheatsheets/INDEX.md` regen
script appends a verified-marker to each line so agents (read-only view)
see that the verbatim source exists, without seeing the bytes themselves.

## Risks / Trade-offs

- **LFS adoption cost**: contributors must `git lfs install` once. Not
  zero friction but standard practice for repos with binary-ish payloads.
- **Bulk-fetch latency on first run**: ~80 cheatsheets × ~2 URLs each ×
  ~2 seconds per fetch = 5+ minutes. One-time cost.
- **Domain allowlist is conservative**: legitimate sources may fail the
  initial bundle check and require `--manual-review`. The trade-off is
  zero accidental license violations.
- **Sidecar drift across re-fetches**: a vendor changes their docs HTML
  layout (no content change); the SHA shifts; cheatsheet maintainer must
  re-bless. Acceptable — the SHA shift triggers human review, which is
  the whole point of the layer.
- **Manual-review path for vendor docs** means cloud-vendor citations get
  the file on-disk locally but NOT committed. Maintainers running CI on
  a PR see the missing files, but the sidecar (committed) tells them how
  to reproduce locally. Documented in the cheatsheet for the validator.

## Sources of Truth

- `docs/strategy/cheatsheet-source-layer-plan.md` — the Opus design memo
  this proposal compresses.
- `cheatsheets/TEMPLATE.md` — the cheatsheet authoring template extended
  by this change to require the `local:` field in Provenance.
- `cheatsheets/runtime/cheatsheet-frontmatter-spec.md` — frontmatter
  contract this change extends.
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — host-side
  path taxonomy this change pins `cheatsheet-sources/` to (COLD path).
- `docs/strategy/forge-hot-cold-split-plan.md` — the upcoming hot/cold
  split this change is the cold-path counterpart of.
- `scripts/regenerate-cheatsheet-index.sh` — model for the new
  `regenerate-source-index.sh` script.
- `scripts/check-cheatsheet-refs.sh` — model for the new
  `check-cheatsheet-sources.sh` validator.
