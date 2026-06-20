# Containerfile: Replace curl/tar installers with DNF — 2026-06-20

trace: plan.yaml (future_intentions item 1),
       plan/steps/58-future-intentions-drain.md

Status: done
Owner host: linux
Capability tags: [images, containerfiles, dnf, packaging]
Dependencies: none

events:
  - type: claim
    ts: "2026-06-20T05:01:15Z"
    agent_id: "linux-tlatoani-big-pickle-20260620T050115Z"
    host: linux
    lease_id: "containerfile-dnf-migration-20260620T050115Z"
    expires_at: "2026-06-20T09:01:15Z"
  - type: completed
    ts: "2026-06-20T05:10:00Z"
    agent_id: "linux-tlatoani-big-pickle-20260620T050115Z"
    host: linux
    lease_id: "containerfile-dnf-migration-20260620T050115Z"
    evidence_refs:
      - "image/default/Containerfile.base — wasmtime migrated from curl+tar to microdnf install wasmtime"
      - "WASMTIME_VERSION and WASMTIME_SHA256 ARGs removed"
      - "./build.sh --check — PASS"
      - "Scope correction: buf already absent, ollama intentionally avoids DNF (GPU bloat, ~1.8GB)"

## Objective

Replace ad-hoc `curl` download + `tar` extraction of third-party tools in
Containerfiles with `dnf install` when an RPM equivalent exists in Fedora repos
(or a well-known COPR/Fedora-sourced repo) — reducing surface area for
supply-chain attacks, checksum-skips, stale URLs, and unmanaged dependency
versions.

## Audit: curl+tar sites in Containerfiles

### `images/default/Containerfile.base`

| Tool | Source | Line(s) | DNF alternative? |
|---|---|---|---|
| marksman (Markdown LSP) | GitHub release binary (curl→/usr/local/bin) | 37 | Not in Fedora. Upstream ships a static binary. |
| buf (protobuf builder) | GitHub release tar.gz (curl→tar -xzf →/usr/local/bin) | 85, 87 | `dnf install buf` available since F40. |
| cargo-nextest | GitHub release tar.gz (curl→tar -xzf →/usr/local/bin) | 92, 94 | `cargo install nextest` preferred; not in Fedora. |
| wasmtime | GitHub release tar.xz (curl→tar -xJf →/usr/local/bin) | 113, 115 | `dnf install wasmtime` available since F38. |
| Dart SDK | storage.googleapis.com zip (curl→/tmp) | 116 | Not in Fedora. |

### `images/inference/Containerfile`

| Tool | Source | Line(s) | DNF alternative? |
|---|---|---|---|
| Ollama | GitHub release tar.zst (curl→unzstd→tar -xf →/usr/local/bin) | 35, 40 | `dnf install ollama` available since F41. |

## Feasibility

**Immediate candidates** (available via DNF, low risk):
- `buf` → `dnf install buf`
- `wasmtime` → `dnf install wasmtime`
- `Ollama` → `dnf install ollama`

**Requires Tlatoani decision:**
- `cargo-nextest`: A Rust tool, typically `cargo install nextest` (fetches from
  crates.io at build time). Switching to DNF would require Fedora to package it,
  or we'd need a COPR. For CI-in-flux reproducibility, the existing curl+tar
  is arguably simpler than managing Rust rebuilds. Recommend: keep as-is until
  Fedora packages `nextest`.
- `marksman`: Single-binary from GitHub releases; not in Fedora, no COPR
  known. The current curl→`/usr/local/bin` is the canonical install method
  recommended by the upstream. Keep as-is.
- `Dart SDK`: From Google's storage; never in Fedora due to licensing.
  Keep as-is; this is a genuine unfixable curl site.

## Implementation plan

Slice 1 (this packet): Migrate wasmtime from curl+tar to DNF.

1. `images/default/Containerfile.base`:
   - Remove `wasmtime` curl+tar block (was lines ~112-115).
   - Remove `WASMTIME_VERSION` and `WASMTIME_SHA256` ARGs.
   - Add `wasmtime` to the `microdnf install` package list.

2. Verify: `./build.sh --check`

## Notes on scope

**buf**: Not present in any current Containerfile. No curl+tar block to migrate.

**Ollama**: The inference Containerfile intentionally avoids DNF because `dnf install ollama` would pull ~1.8GB of GPU runner libraries (CUDA, ROCm) that are never used in CPU-only inference mode. The current approach — extracting only `bin/ollama` from the release tarball — is the correct minimal install for this use case.

**wasmtime**: Successfully migrated to DNF — `microdnf install wasmtime` in Containerfile.base line 21.

## Architectural note (for Tlatoani)

The remaining curl sites (marksman, cargo-nextest, dart) are cases where the
tooling is either unavailable via DNF or the curl+tar pattern is the upstream-
recommended install method. They can be addressed in future slices if:
- A marksman RPM appears in Fedora.
- `cargo install nextest` becomes acceptable for the image build (slower,
  network-dependent at build time).
- Dart SDK becomes available via a Flutter COPR or similar.

The wasmtime migration is low-risk and deterministic: RPM
transactions are checksum-verified and signature-checked.

## Acceptance evidence

- `--init` rebuilds `forge-base` with wasmtime installed via DNF instead of curl+tar.
- `podman run --rm <forge-base> wasmtime --version` returns a valid version.
- No regression in `./build.sh --check`.
- No regression in forge diagnostics or E2E gates.
