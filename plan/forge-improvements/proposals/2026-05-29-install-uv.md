---
title: Install uv (Astral Python package manager)
gap: UV_CACHE_DIR is exported in lib-common.sh but uv is not installed in the forge image
category: runtime-tool
status: proposed
proposed_at: 2026-05-29T18:30:00Z
changes:
  - file: images/default/Containerfile
    description: Add uv installation after the Python3/pip install layer. uv can be installed via `pip install uv` once Python3 is available, or via the standalone installer (`curl -fsSL https://astral.sh/uv/install.sh | sh`). UV_CACHE_DIR is already exported by lib-common.sh routing uv cache to the per-project cache.
approved_by: null
---

## Gap

The forge image exports `UV_CACHE_DIR` (lib-common.sh:554) routing uv's package cache to the per-project cache. However, no `uv` CLI is installed in the image.

This means:

1. `UV_CACHE_DIR` is a dead env var — agents who try `uv pip install ...` or `uv venv` get `command not found`
2. `tillandsias-inventory` (line 27) lists uv under Build tools
3. `cache-discipline.md` documents the uv cache path convention
4. uv is the recommended Python package manager for new projects (Astral's pip replacement, 10-100x faster than pip)
5. Agents using Python workflows cannot benefit from uv's fast dependency resolution

Note: uv requires Python3 to be installed first. Python3 installation is covered by the existing proposal `2026-05-29-install-python3-pip.md`. If that proposal is approved and implemented first, uv can be added via `pip install uv`.

## Evidence

- `images/default/lib-common.sh` line 554: `export UV_CACHE_DIR="$PROJECT_CACHE/uv"`
- `images/default/cli/tillandsias-inventory` line 27: lists uv as expected Build tool
- `images/default/config-overlay/opencode/instructions/cache-discipline.md`: documents uv cache path
- uv depends on Python3 (covered by existing proposal 2026-05-29-install-python3-pip.md)

## Safety

- uv can be installed via the official Astral installer (HTTPS, verified) or via `pip install uv` once Python3 is present
- UV_CACHE_DIR already points to per-project cache
- No credentials or secrets are involved
- uv is MIT-licensed and widely adopted (used by 40%+ of Python developers per JetBrains survey)
