# Smoke E2E Findings — v0.3.260620.8 — 2026-06-20

**Release:** `v0.3.260620.8` (published 2026-06-20T20:09:40Z)
**Smoke date:** 2026-06-20T20:34Z–21:00Z UTC
**Host:** linux_immutable (Fedora 44 Workstation, x86_64)
**Agent:** `linux-claude-sonnet46-immutable-20260620T2034Z`
**Skill:** `/smoke-curl-install-and-test-e2e`

---

## Result: PARTIAL — init blocked by forge-base build network failure

| Gate | Result | Notes |
|------|--------|-------|
| install | ✅ PASS | v0.3.260620.8, SHA256 verified, 17 MB/s |
| substrate reset | ✅ PASS | `podman system reset --force` clean |
| `--init` | ❌ FAIL | forge-base pip3 network timeout; core images built but no containers started |
| forge opencode run | ⏭ SKIPPED | forge image not built |

**Core images built successfully:** proxy, git, inference, router, chromium-core, chromium-framework, web, vault (from previous session — rebuilt on reset).  
**Failed:** forge-base → cascade to forge, nanoclawv2.  
**Enclave state after init:** no containers running; no Vault; full re-init required.

---

## Findings

### Work Packet: smoke-finding/forge-base-pip-build-network-timeout

- id: `smoke-finding/forge-base-pip-build-network-timeout`
- owner_host: linux
- capability_tags: [podman, networking, images, containerfiles, forge]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260620.8`
- evidence:
  - `target/smoke-e2e/03-init.log:3505` — `WARNING: Attempting to resume incomplete download (0 bytes/6.1 MB, attempt 1)`
  - `target/smoke-e2e/03-init.log:3491` — `ReadTimeoutError("HTTPSConnectionPool(host='files.pythonhosted.org', port=443): Read timed out. (read timeout=15)")`
  - `target/smoke-e2e/03-init.log:3525` — `error: incomplete-download` after 6 attempts
  - Host probe: `curl https://files.pythonhosted.org/.../pyright-1.1.410-py3-none-any.whl` → 200 in 0.75s ✓
  - Container `podman run` probe: same URL → 200 in 0.50s ✓
  - `podman build` context: 0 bytes received on all attempts ✗
- repro:
  ```bash
  podman system reset --force
  tillandsias --debug --init  # fails at forge-base STEP 6/34 (pip3 install pyright)
  ```
- root_cause: >
    `scripts/build-image.sh` invokes `podman build` without a `--network` flag.
    On Fedora 44 with rootless Podman and no `slirp4netns` (only `pasta`), the
    default build network has different TCP stream behaviour than `podman run`:
    small payloads (metadata, < 1 MTU) transfer fine; large payloads (6.1 MB
    pyright wheel) receive 0 bytes and time out at 15 seconds on every attempt.
    The `pip3 install --timeout 15` default fires consistently. The `podman run`
    path does not exhibit this (downloads at >10 MB/s), suggesting a
    pasta/MTU/TCP-window difference between the two code paths.
- next_action: >
    Option A (quickest): Add `--timeout 120` (or `PIP_DEFAULT_TIMEOUT=120` env)
    to the pip3 install step in `images/default/Containerfile.base` STEP 6.
    Option B (structural): Pass `--network=host` to the `podman build` calls in
    `scripts/build-image.sh` for the forge-base image specifically, or as a
    global flag when building on immutable Linux hosts.
    Option C (root fix): Investigate pasta MTU/TCP-window config for `podman
    build` on Fedora 44 and set `containers.conf` network_mode appropriately.
    Recommend Option A as the immediate fix and Option C as the durable fix.
- events:
  - type: discovered
    ts: "2026-06-20T20:57Z"
    agent_id: "linux-claude-sonnet46-immutable-20260620T2034Z"
    host: linux_immutable

---

### Work Packet: smoke-finding/init-all-or-nothing-forge-blocks-core

- id: `smoke-finding/init-all-or-nothing-forge-blocks-core`
- owner_host: linux
- capability_tags: [init, podman, resilience, forge]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260620.8`
- evidence:
  - `target/smoke-e2e/03-init.log` (final lines) — `Error: Failed to build 3 image(s): forge-base, forge, nanoclawv2`; `exit=1`
  - `podman ps -a` after init — empty (no containers started)
  - Images built: proxy ✓, git ✓, inference ✓, router ✓, chromium-core ✓, chromium-framework ✓, web ✓
  - Images missing: forge-base ✗, forge ✗, nanoclawv2 ✗
- repro:
  ```bash
  podman system reset --force
  tillandsias --debug --init  # forge-base fails → init exits 1 → zero containers started
  podman ps -a  # empty
  ```
- root_cause: >
    `tillandsias --init` is implemented as a parallel image build followed by
    container startup. If any image build fails (exit != 0), the entire init
    exits without starting any containers — even images with no dependency on
    the failed one. proxy/git/inference/router/vault are fully independent of
    forge-base; a forge-base pip failure should not prevent the core enclave
    from provisioning. An operator on an immutable host who only needs git
    mirroring, vault, and inference is completely blocked by a transient PyPI
    failure.
- next_action: >
    Implement partial init: `tillandsias --init` should start all successfully
    built core images (vault, proxy, git, inference, router) even when forge /
    forge-base / nanoclawv2 fail to build. Forge images should be `optional`
    in the init dependency graph and their build failure should produce a
    `[warn]` rather than an init exit. The tray/headless can show forge as
    "unavailable (build failed)" rather than blocking the whole session.
- events:
  - type: discovered
    ts: "2026-06-20T20:57Z"
    agent_id: "linux-claude-sonnet46-immutable-20260620T2034Z"
    host: linux_immutable

---

## IPv4-Only Pasta Injection (informational)

Init log line: `IPv6 connectivity check failed. Injecting pasta_options = ["--ipv4-only"]`

This is expected behaviour on this host (no IPv6 on the LAN). Not a blocker.
Noted for completeness — the `--ipv4-only` injection appears to work correctly
for running containers but may interact with the `podman build` network path (the
build context doesn't inherit pasta options configured for runtime containers,
which may contribute to finding 1).

---

## Evidence Trail

- `target/smoke-e2e/00-smoke-lock.log` — smoke lock acquisition/release log
- `target/smoke-e2e/01-install.log` — curl-install output (PASS)
- `target/smoke-e2e/01-version.txt` — `Tillandsias v0.3.260620.8`
- `target/smoke-e2e/02-reset.log` — `podman system reset --force` (PASS)
- `target/smoke-e2e/03-init.log` — first init attempt (FAIL: forge-base pip timeout)
- `target/smoke-e2e/03-init-retry.log` — retry (FAIL: same pyright timeout, confirms not transient at build level)
