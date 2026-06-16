# Forge Continuous Enhancement — Findings 2026-06-16

**Host:** Linux / `linux-next`
**Status:** research complete; work packets filed for pickup
**Scope:** plan files only. No Containerfile, scripts, or code changed.

## Review Performed

Executed the `/forge-continuous-enhancement` skill against the current
`linux-next` checkout. Reviewed:

- `images/default/Containerfile.base` — Fedora Minimal base image
- `images/default/Containerfile` — forge runtime image
- `scripts/build-image.sh` — build orchestration
- `scripts/generate-dashboard.sh` — dashboard generation
- `plan/metrics-dashboard.md` — current telemetry dashboard
- Existing research: `plan/issues/container-build-efficiency-telemetry-2026-06-08.md`
- Existing scope: `plan/issues/forge-package-manager-and-telemetry-2026-06-12.md`

## Finding 1: Containerfile.base split already done, curl/dnf migration largely complete

The `Containerfile` split into `Containerfile.base` + `Containerfile` (requirement
#5 from the forge-package-manager issue) is already in effect.

Most migrations identified in the 2026-06-08 research have been applied:
- Rust toolchain from Fedora (`rust`, `cargo`, `clippy`, `rustfmt`,
  `rust-analyzer`, `cargo-deny`)
- Python tools from Fedora (`ruff`, `poetry`, `pipx`, `uv`, `black`, `pylint`,
  `yamllint`, `python3-mypy`, `python3-pytest`, `python3-lsp-server`)
- JS package managers from Fedora (`pnpm`, `yarnpkg`)
- Go debugger (`delve`), shell formatter (`shfmt`) from Fedora

**Unchanged curl/tar installs** — all verified as NOT available in Fedora 44
during the 2026-06-08 research:
- `cargo-nextest`, `cargo-chef`, `cargo-watch`, `cargo-audit`, `wasm-pack`,
  `trunk`, `typos-cli`, `watchexec-cli`, `cargo-edit`, `cargo-llvm-cov`,
  `cargo-semver-checks`, `cargo-expand`, `cargo-criterion`, `cargo-wasi`,
  `cargo-outdated`, `actionlint`, `vale`, `wasmtime`, `dart`

These remain pinned direct-release installs with SHA-256 verification, which
is the correct approach per the research recommendations.

## Finding 2: Telemetry infrastructure present but incomplete

`scripts/build-image.sh` (lines 591-606) already writes build metrics:

```jsonl
{"timestamp": "...", "image": "forge", "duration_s": 123,
 "size_bytes": 456, "hash": "sha256-..."}
```

And `scripts/generate-dashboard.sh` produces `plan/metrics-dashboard.md` with
Mermaid `xychart-beta` graphs.

**Gaps vs. the telemetry contract in `container-build-efficiency-telemetry-2026-06-08.md`:**

1. **No per-component install timing** — the telemetry records only total build
   duration per image, not time spent in individual RUN steps or curl downloads.
2. **No download size tracking** — `bytes_downloaded` is not recorded.
3. **No build decision metadata** — skip/build/force/retag decision is implicit
   in the log output but not recorded in telemetry.
4. **No cache result** — cache hit/partial/miss is not tracked.
5. **No OCI labels** — images carry no `io.tillandsias.*` or
   `org.opencontainers.image.*` labels.
6. **No build event ID or ULID** — events are not correlated across stages.
7. **No `build-*.log` telemetry parsing** — the Containerfile base image build
   output (`build-forge.log`) is available but not mined for per-step metrics.

## Finding 3: Per-step instrumentation opportunity in Containerfile.base

The `install_archive` function in `Containerfile.base` (lines 76-83) is a
single RUN block that downloads and extracts 16 archive-based tools
sequentially. No `time` or `date` instrumentation tracks individual download
or extraction durations.

The single `microdnf install` RUN command (lines 8-25) installs ~30 packages
in one layer. No per-package timing exists.

**Recommendation:** Add `time` wrappers or `date` markers inside the
Containerfile RUN commands so individual step durations are visible in build
logs. These can then be parsed by `scripts/generate-dashboard.sh` or a new
log-parsing script.

## Finding 4: No dashboard timeline component for per-component metrics

The current Mermaid dashboard at `plan/metrics-dashboard.md` only shows overall
build duration and final image size for the forge image.

No chart tracks:
- Per-component install time (e.g., how long each `install_archive` call took)
- Download sizes per component
- Build-to-build trend of individual components

**Recommendation:** Extend `scripts/generate-dashboard.sh` to parse timestamps
from `build-forge.log` (or a future structured output file) and render
per-component bar/line charts.

## Work Packets for `/advance-work-from-plan`

### Packet A: Containerfile.base per-step timing

- Instrument the `install_archive` function and `microdnf install` step with
  `time` or `date +%s%3N` wrappers.
- Persist per-step timing data for post-build log parsing.
- Dependencies: none (Containerfile-only change).
- Estimated effort: 3h.

### Packet B: Structured telemetry contract implementation

- Align `build-image.sh` telemetry with the `container-build-efficiency-telemetry`
  contract (event_id, build_decision, cache_result, bytes_downloaded,
  per-step timing).
- Add OCI labels to forge images.
- Dependencies: Packet A for per-step timing source data.
- Estimated effort: 5h.

### Packet C: Dashboard enhancement

- Extend `scripts/generate-dashboard.sh` to parse per-step timing from
  build logs and render per-component Mermaid timeline charts.
- Add trend history tracking beyond the current last-20-builds window.
- Dependencies: Packet A or B for the data source.
- Estimated effort: 4h.
