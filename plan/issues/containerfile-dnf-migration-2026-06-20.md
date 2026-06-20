# Containerfile: Replace curl/tar installers with DNF — 2026-06-20

trace: plan.yaml (future_intentions item 1),
       plan/steps/58-future-intentions-drain.md

Status: ready
Owner host: linux
Capability tags: [images, containerfiles, dnf, packaging]
Dependencies: none

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

Slice 1 (this packet): Replace 3 confirmed DNF-available tools.

1. `images/default/Containerfile.base`:
   - Remove `buf` curl+tar block (lines ~85-87).
   - Remove `wasmtime` curl+tar block (lines ~113-115).
   - Add `buf` and `wasmtime` to the `dnf install` package list (currently line ~12).

2. `images/inference/Containerfile`:
   - Remove Ollama curl+unzstd+tar block (lines ~35-40).
   - Add `ollama` to the `dnf install` package list.

3. Verify: `scripts/build-image.sh base && scripts/build-image.sh inference`

4. Rebuild forge base and inference images as part of the next `--init`.

## Architectural note (for Tlatoani)

The remaining curl sites (marksman, cargo-nextest, dart) are cases where the
tooling is either unavailable via DNF or the curl+tar pattern is the upstream-
recommended install method. They can be addressed in future slices if:
- A marksman RPM appears in Fedora.
- `cargo install nextest` becomes acceptable for the image build (slower,
  network-dependent at build time).
- Dart SDK becomes available via a Flutter COPR or similar.

The current three DNF candidates are low-risk and deterministic: RPM
transactions are checksum-verified, signature-checked (when
`dnf install --setopt=repo_gpgcheck=1`), and the download count drops from
6 curl sites to 3.

## Acceptance evidence

- `--init` rebuilds `forge-base` and inference images without curl/tar for the
  migrated tools.
- `podman run --rm <forge-base> buf version` returns a valid version string.
- `podman run --rm <forge-base> wasmtime --version` returns a valid version.
- `podman run --rm <inference> ollama --version` returns a valid version.
- No regression in forge diagnostics or E2E gates.
