---
title: Install Python3 and pip for build systems and agent workflows
gap: Python runtime is missing from the forge image; PIP_CACHE_DIR is exported in lib-common.sh but no Python/pip is installed
category: runtime-tool
status: proposed
proposed_at: 2026-05-29T10:50:00Z
changes:
  - file: images/default/Containerfile
    description: Add `python3 python3-pip` to the microdnf install RUN layer. Python3 is needed for build scripts (setuptools, meson, ninja), agent-driven Python tooling, and the distill script which runs python3 to parse diagnostics JSON.
approved_by: null
---

## Gap

The forge image exports `PIP_CACHE_DIR` (line 557 of `lib-common.sh`) and `UV_CACHE_DIR` (line 554), routing pip/uv caches into the per-project cache, but neither Python3 nor pip is installed in the image.

The `scripts/distill-forge-diagnostics.sh` script explicitly requires `python3` for JSON parsing.

The forge-completeness-baseline audit (`plan/diagnostics/forge-completeness-baseline-2026-05-27.md`) notes per-language env vars are at PROMPT coverage level only — but for Python, there is no runtime to actually test.

## Evidence

- `images/default/Containerfile` lines 17-24: no python3 package
- `images/default/lib-common.sh` line 557: `export PIP_CACHE_DIR="$PROJECT_CACHE/pip"`
- `images/default/lib-common.sh` line 554: `export UV_CACHE_DIR="$PROJECT_CACHE/uv"`
- `scripts/distill-forge-diagnostics.sh` line 86: `if command -v python3 &>/dev/null; then`
- Fedora Minimal 44 has `python3` available via microdnf (~30 MB with pip).

## Safety

- Python3 is a standard Fedora package — no untrusted binaries, no network fetch.
- PIP_CACHE_DIR already points to the per-project cache, so pip downloads will use the designated cache mount.
- No credentials or secrets are involved.
