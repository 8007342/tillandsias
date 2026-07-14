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

## Update — 2026-07-13 (fresh-Silverblue manifestation + partial mitigation)

New manifestation on a pristine host (yolanda, Fedora Silverblue): after the
operator's first `tillandsias --init`, `~/.config/containers/containers.conf`
carries the `[engine] env` proxy block, so `toolbox create` (fedora-toolbox
image pull) and every other host-side `podman pull` fail with
`proxyconnect tcp: dial tcp: lookup proxy: no such host` — the enclave
hostname `proxy` never resolves on the host network. This broke first-time
builder-toolbox provisioning (order 239's "fresh Silverblue host" exit
criterion falsified live).

Wrapper-side mitigation landed on linux-next 2026-07-13:
`scripts/with-tillandsias-builder.sh` now exports empty-string overrides for
http_proxy/https_proxy/HTTP_PROXY/HTTPS_PROXY/all_proxy/ALL_PROXY (only when
unset in the caller's environment) before toolbox/podman operations — the same
neutralization pattern as BUILD_PROXY_NEUTRALIZE_VARS in tillandsias-headless.
Verified live: toolbox image pull + dnf + rustup all succeed on the poisoned
host.

Still open (the actual fix): non-tillandsias podman consumers on the host
(operator `podman pull`, other tools) remain poisoned whenever the proxy
container is not running. The reset/teardown path (or init itself) should
scope the proxy env to enclave containers instead of the user-global
`[engine] env`, or clean it up when the stack is town down.
