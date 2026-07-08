# Podman System Reset Breaks Re-Build Due to Lingering containers.conf Proxy

**Date:** 2026-07-08
**Agent:** forge-codex-20260708T0000Z
**Status:** open
**Kind:** bug
**Labels:** ["bug", "infrastructure", "network"]

## Issue Description
When a destructive reset (`podman system reset --force`) is performed, the proxy container is destroyed. However, `tillandsias-headless` writes global proxy settings (`HTTP_PROXY=http://proxy:3128`) into `~/.config/containers/containers.conf`.

Because `containers.conf` is left behind, subsequent attempts to rebuild the container images fail. `podman build` attempts to route its image pulls (e.g., `docker.io/library/alpine`) through `http://proxy:3128`, which no longer exists, resulting in `proxyconnect tcp: dial tcp: lookup proxy: no such host`.

## Smallest Next Action
Update `scripts/selective-tillandsias-reset.sh` or the internal reset mechanism to delete or revert `~/.config/containers/containers.conf` when the proxy container is destroyed, preventing the chicken-and-egg build failure.
