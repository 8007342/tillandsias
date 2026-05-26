#!/usr/bin/env bash
# Step 30 — pre-pull the podman enclave's base container images into the
# VM rootfs so the first user-action (--github-login, --opencode, etc.)
# does NOT wait on container image download.
#
# The Tillandsias enclave model (see CLAUDE.md "Enclave Architecture")
# uses 4 inner containers built from images under repo `images/`:
#   tillandsias-proxy        caching HTTP/S proxy
#   tillandsias-git          bare git mirror + post-receive sync
#   tillandsias-forge        dev env / agent host
#   tillandsias-inference    ollama for local LLM
#
# Those images aren't published anywhere — `scripts/build-image.sh` builds
# them locally from `images/<svc>/Containerfile`. For the first cron tick
# this script does nothing (placeholder); future iterations may pre-build
# the images here so the cold-start UX is "boot VM → click → instant" with
# no podman-pull lag.
#
# @trace openspec/changes/vm-recipe-provisioning §1.5

set -euo pipefail

# Enable podman.socket so the in-VM headless can drive containers via the
# REST API rather than shelling out to the `podman` binary every call.
systemctl enable podman.socket 2>/dev/null || true

# TODO (Phase 5+): pre-build the enclave images. Requires the recipe-build
# container to have access to images/<svc>/Containerfile + cheatsheets/.
# For now leave this as a no-op; first user-action will trigger podman
# build on demand. ~30s extra latency on first click; documented in
# plan/steps/20-macos-tray-v0_0_1.md.

echo "[30-enclave] done (placeholder — enclave images built on first user action)"
