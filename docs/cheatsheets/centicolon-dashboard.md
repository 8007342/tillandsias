---
tags: [convergence, centicolon, dashboard, metrics, release]
languages: [bash, markdown, json]
since: 2026-05-06
last_verified: 2026-05-06
sources:
  - methodology/proximity.yaml
  - methodology/versioning.yaml
  - methodology/litmus-centicolon-wiring.yaml
  - scripts/update-convergence-dashboard.sh
authority: internal
status: draft
tier: bundled
---

# CentiColon Dashboard

@trace spec:observability-convergence, spec:versioning, spec:spec-traceability

**Use when**: Regenerating or interpreting the repo-visible convergence dashboard.

## Provenance

- Canonical score shape: `methodology/proximity.yaml`
- Release dashboard requirements: `methodology/versioning.yaml`
- Litmus-to-metric wiring: `methodology/litmus-centicolon-wiring.yaml`
- Renderer: `scripts/update-convergence-dashboard.sh`

## Canonical Inputs

- `target/convergence/centicolon-signature.jsonl`
- `target/convergence/centicolon-delta.json` when available
- Release/evidence metadata embedded in each signature record

## Canonical Outputs

- `docs/convergence/centicolon-dashboard.md`
- `docs/convergence/centicolon-dashboard.json`
- `docs/convergence/github-actions-dashboard.md`
- `docs/convergence/github-actions-dashboard.json`
- `target/convergence/summary.md`
- `target/convergence/github-actions-summary.md`

## Visual Contract

- Latest release appears first.
- Older releases stay visible under the latest row.
- The top strip uses block glyphs to show closed and residual trend across releases.
- Markdown remains the source of truth for GitHub rendering.
- JSON mirrors the same records for agents and automation.

## Regeneration

```bash
scripts/update-convergence-dashboard.sh
```

## Cadence

- Local CI may regenerate the dashboard after every metrics-producing run.
- Main-branch merges should refresh the dashboard and append a new signature record.
- Release runs should publish the dashboard, signature log, delta JSON, and evidence bundle together.
- GitHub Actions should regenerate its own hosted-only dashboard against committed code and upload the artifacts separately from local development metrics.

## Tail Compression

- Keep the most recent raw signature records verbatim.
- Compact older runs into rollup buckets once the raw window is exceeded.
- A compacted bucket must preserve record count, source commit range, worst residual reason, and min/max/last residual values.
- Do not delete history without a tombstone or bucket reference.

## Reading the Dashboard

- `Closed %` is the share of the obligation budget earned by validated evidence.
- `Residual` is remaining named obligation debt, not line count or confidence.
- `Worst spec` and `Worst reason` name the main blocker for the current release row.
- Trend glyphs should be read left to right, oldest to newest.
- Local development and GitHub Actions histories are separate series. Compare them, but do not collapse them into one log.

## Hosted Accountability

- The local series is the high-fidelity development loop.
- The GitHub Actions series is the committed-code accountability loop.
- The hosted series should stay lighter by omitting local-only expensive checks such as podman-backed litmus runs.
- A stable comparison means both series should keep the same residual naming conventions even if their denominators differ.

## Anti-Gaming Rules

- Do not hide denominator changes.
- Do not report percentage without residual cc.
- Do not replace the JSONL signature with the rendered markdown.
- Do not drop failed releases from history without an explicit tombstone.

## Related

- [CentiColon dashboard MD](</var/home/machiyotl/src/tillandsias/docs/convergence/centicolon-dashboard.md:1>)
- [CentiColon dashboard JSON](</var/home/machiyotl/src/tillandsias/docs/convergence/centicolon-dashboard.json:1>)
- [Renderer script](</var/home/machiyotl/src/tillandsias/scripts/update-convergence-dashboard.sh:1>)
