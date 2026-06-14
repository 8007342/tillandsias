# Smoke E2E Findings — Release v0.3.260609.3 — 2026-06-12

Discovered by `/smoke-curl-install-and-test-e2e` skill execution.

---

### Work Packet: smoke-finding/rootless-podman-ipv6-timeout

- id: `smoke-finding/rootless-podman-ipv6-timeout`
- owner_host: linux
- capability_tags: [podman, runtime, testing]
- status: claimed
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260609.3`
- evidence:
  - `target/smoke-e2e/03-init.log:17` — `[tillandsias] build-proxy: fetch https://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64/APKINDEX.tar.gz` (hung indefinitely)
  - `task-87.log` (host `curl -6`) — `curl: (28) Failed to connect to dl-cdn.alpinelinux.org port 443 after 133742 ms`
- repro:
  - Run `podman run --rm docker.io/library/alpine:3.20 apk update` on a host with a dynamically assigned IPv6 address but no functional IPv6 routing.
- next_action: >
    Document this rootless Podman IPv6 issue in troubleshooting docs. Check if the installer or the `tillandsias` tool can auto-detect broken IPv6 or write the `pasta_options = ["--ipv4-only"]` to the user's `containers.conf` automatically during initialization.
- events:
  - type: discovered
    ts: `2026-06-12T21:44:00Z`
    agent_id: `linux-tlatoani-gemini-3.5-flash-2026-06-12`
    host: linux
  - type: claim
    ts: `2026-06-14T00:25:00Z`
    agent_id: `linux-tlatoani-gemini-20260614T001417Z`
    host: linux
    lease_id: `lease-linux-rootless-podman-ipv6-20260614T002500Z`
    expires_at: `2026-06-14T04:25:00Z`

---

### Work Packet: smoke-finding/vault-init-build-path-spawn

- id: `smoke-finding/vault-init-build-path-spawn`
- owner_host: linux
- capability_tags: [rust, vault, testing, release]
- status: done
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260609.3`
- evidence:
  - `target/smoke-e2e/03-init.log:3769` — `[tillandsias-vault] running /build/source/scripts/build-image.sh vault`
  - `target/smoke-e2e/03-init.log:3770` — `Error bringing Vault up: failed to spawn /build/source/scripts/build-image.sh: No such file or directory (os error 2)`
- repro:
  - Run `tillandsias --debug --init` from a pristine state using a packaged release binary on a machine where `/build/source/` does not exist.
- next_action: >
    Modify `crates/tillandsias-headless/src/vault_bootstrap.rs` to build the vault image using the Rust `ImageBuilder` trait (same as the other enclave images) instead of spawning `scripts/build-image.sh` via a hardcoded compilation-time `CARGO_MANIFEST_DIR` parent path.
- events:
  - type: discovered
    ts: `2026-06-12T21:50:00Z`
    agent_id: `linux-tlatoani-gemini-3.5-flash-2026-06-12`
    host: linux
  - type: claim
    ts: `2026-06-14T00:19:00Z`
    agent_id: `linux-tlatoani-gemini-20260614T001417Z`
    host: linux
    lease_id: `lease-linux-vault-init-build-path-20260614T001900Z`
    expires_at: `2026-06-14T04:19:00Z`
  - type: completed
    ts: `2026-06-14T00:25:00Z`
    agent_id: `linux-tlatoani-gemini-20260614T001417Z`
    host: linux
    commits:
      - `c35077f5`
    validation_logs:
      - `/home/tlatoani/.gemini/antigravity/brain/993e15ab-af60-4fef-bab0-6fa945ba436e/.system_generated/tasks/task-293.log`
