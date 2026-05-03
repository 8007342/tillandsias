# download-telemetry Specification

## Status

status: active

## Purpose
TBD - created by archiving change forge-cache-architecture. Update Purpose after archive.
## Requirements
### Requirement: Every runtime download emits a structured log event

Every byte fetched at runtime by Tillandsias-managed processes (host tray, forge containers, inference container, image-build subprocesses, future host-Chromium downloader) SHALL emit a structured `tracing` log event with the following fields:

| Field | Required | Type | Meaning |
|---|---|---|---|
| `accountability` | yes | bool | always `true` for downloads |
| `category` | yes | string | always `"download"` |
| `url` | yes | string | source URL (or `<local>` for cache-internal copies) |
| `bytes` | yes | u64 | bytes transferred |
| `target` | yes | string | absolute or category-relative target path |
| `reason` | yes | string | `"cache-miss"` / `"version-bump"` / `"first-launch"` / `"user-requested"` / `"forced-rebuild"` |
| `source` | yes | string | `"host-tray"` / `"forge:<project>"` / `"inference"` / `"router-image-build"` / etc. |
| `duration_ms` | yes | u64 | time the download took |

The event message text SHALL be `"downloading"` for the start, `"downloaded"` for completion, `"download-failed"` for failures.

#### Scenario: cargo cache miss emits a download event
- **WHEN** an agent inside the forge for project `foo` runs `cargo build` and a crate is not in the per-project cache
- **THEN** the crate fetch SHALL emit a log event with `category="download"`, `source="forge:foo"`, `target` pointing under `/home/forge/.cache/tillandsias-project/cargo/`, `reason="cache-miss"`
- **AND** the event SHALL include the source URL and bytes transferred

#### Scenario: Cache-hit emits no download event
- **WHEN** the same crate is requested on a second build with no version change
- **THEN** NO `category="download"` event MUST be emitted (the bytes never crossed the network)

### Requirement: tillandsias --download-stats reports the aggregate

A new host-side CLI subcommand `tillandsias --download-stats [--since=<duration>]` SHALL parse the accountability log, filter events with `category="download"`, and report:

- Total bytes downloaded in the window
- Top 10 sources by bytes
- Top 10 reasons by count
- A per-day timeseries

Default `--since=24h`. The command is for power users / metrics inspection — there MUST be NO tray menu item, NO desktop notification, NO new prompt.

#### Scenario: Power user inspects yesterday's downloads
- **WHEN** the user runs `tillandsias --download-stats --since=24h`
- **THEN** the command SHALL exit 0 with a textual report on stdout
- **AND** the report SHALL include total bytes, per-source breakdown, per-reason breakdown
- **AND** if zero downloads occurred, the report SHALL say `"no downloads in last 24h ✓"`

#### Scenario: Convergence target — zero in steady state
- **WHEN** the forge image and per-project caches are warm AND the user is in steady-state development
- **THEN** `tillandsias --download-stats --since=1h` SHALL report close to 0 bytes (allowing only OCI layer pulls / image updates / explicit dep-version bumps in user code)
- **AND** any non-zero value in steady state SHALL be investigable via the per-source breakdown

### Requirement: Downloads to the project workspace are flagged as anti-pattern

When an agent inside the forge writes a file ≥ 1 MB to the project workspace (`/home/forge/src/<project>/`) AND the file's source was a network URL (downloaded JAR, vendored binary, etc.), the download telemetry SHALL flag it with `reason="workspace-anti-pattern"` so the metric system surfaces the issue without blocking the operation.

This addresses the `../java/` audit's finding: the test agent committed a 200 MB JDK + Log4j JAR into the repo because it didn't know the forge already had them. With this telemetry, the issue is observable on the next `--download-stats` query.

#### Scenario: Big file written to project workspace flagged
- **WHEN** an agent runs a command that downloads a 100 MB JAR and writes it to `/home/forge/src/<project>/lib/`
- **THEN** the download event SHALL carry `reason="workspace-anti-pattern"` (not `"cache-miss"`)
- **AND** `tillandsias --download-stats` SHALL surface it under a "anti-patterns" header in addition to the per-source breakdown


## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/architecture/event-driven-basics.md` — Event Driven Basics reference and patterns

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Telemetry downloads do not persist; no lingering download state
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:download-telemetry" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
