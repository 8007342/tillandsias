## MODIFIED Requirements

### Requirement: Forge containers are enclave-only

Forge units (containers on Linux/macOS, WSL distros on Windows) SHALL be attached to the enclave-only network and SHALL have no direct internet egress. All HTTP/HTTPS traffic SHALL go through the proxy.

> Delta: prior wording assumed a single mechanism (podman `--network=enclave-internal`). On Windows the WSL VM hosts every distro in one shared Linux network namespace, so the mechanism splits per platform. The Linux/macOS path is unchanged. The Windows path is enforced by two independent, simultaneously-active layers; either alone is sufficient, both together are mandatory.

#### Scenario: Linux/macOS — direct internet access blocked

- **GIVEN** a forge container attached to `tillandsias-enclave` (podman `--network=enclave-internal`)
- **WHEN** the agent inside runs `curl --max-time 2 https://example.com`
- **THEN** the connection SHALL fail (no route to host)

#### Scenario: Windows — direct internet access blocked

- **GIVEN** a forge WSL distro running an agent as `uid=2003` (in the forge uid range 2000-2999)
- **WHEN** the agent runs `curl --max-time 2 https://example.com`
- **THEN** the connection SHALL fail with "Network is unreachable" or equivalent

#### Scenario: Package install through proxy works

- **WHEN** the forge runs a package install with the proxy env vars set (`HTTP_PROXY` / `HTTPS_PROXY` from `tillandsias-services proxy 3128`)
- **THEN** the install SHALL succeed

## ADDED Requirements

### Requirement: Windows forge-offline uses two independent enforcement layers

On `target_os = "windows"`, forge-offline SHALL be enforced by both Layer 1 (uid-based iptables egress drop in the shared netns) AND Layer 2 (`unshare --net` at agent process spawn). Either layer alone is sufficient; both together are mandatory and form defense in depth. The tray SHALL refuse to attach when either layer's smoke probe fails.

#### Scenario: Layer 1 — iptables egress drop applied at VM boot

- **GIVEN** the WSL VM has just cold-booted (no enclave-init yet)
- **WHEN** the `enclave-init` distro runs (registered via `[boot] command` in its `wsl.conf`)
- **THEN** `iptables -L OUTPUT -v` SHALL show two rules:
  - `OUTPUT … -m owner --uid-owner 2000-2999 -d 127.0.0.0/8 -j ACCEPT`
  - `OUTPUT … -m owner --uid-owner 2000-2999 -j DROP`
- **AND** these rules SHALL apply to every WSL distro in the same VM (shared netns)

#### Scenario: Layer 2 — agent process re-namespaces network

- **GIVEN** a forge entrypoint that has been migrated to call `unshare --net`
- **WHEN** the entrypoint exec's the agent
- **THEN** the agent process SHALL run in a fresh net namespace whose only interface is `lo`
- **AND** outbound traffic to non-loopback SHALL fail at the kernel level even if Layer 1 is somehow disabled

#### Scenario: Pre-attach smoke probe verifies both layers

- **GIVEN** "Attach Here" has been clicked but the agent has not been exec'd yet
- **WHEN** the tray runs the pre-attach probe inside the forge distro:
  1. `curl --max-time 2 https://example.com` (must FAIL)
  2. `curl --max-time 2 http://127.0.0.1:3128/health` (must SUCCEED)
- **THEN** the tray SHALL proceed to spawn the agent only when both probe results match expectation
- **AND** if either disagrees, the tray SHALL surface a "forge-offline integrity check failed" notification and refuse to attach

#### Scenario: Disabling Layer 1 does not silently break the contract

- **GIVEN** Layer 1 has been disabled (e.g., enclave-init failed to start)
- **WHEN** "Attach Here" is clicked
- **THEN** the pre-attach probe step 1 SHALL fail (the iptables drop is gone)
- **AND** the tray SHALL refuse to attach
- **AND** the user SHALL see a remediation message instructing them to restart the WSL VM

### Requirement: Forge uid range is reserved

Forge agent processes on Windows SHALL run as a uid in the range `[2000, 2999]` inclusive. proxy, git, inference, router SHALL run as uids OUTSIDE that range. The tray SHALL allocate a fresh uid per attach (incrementing within `[2000, 2999]`, wrapping at 2999). This range is the single value Layer 1's iptables rule keys on; misalignment between the rule and the actual process uid would silently break offline-ness.

#### Scenario: tray issues `wsl --user 2003 --exec`

- **WHEN** the tray launches an agent in a forge clone
- **THEN** the `wsl.exe` invocation SHALL include `--user 2003` (or another uid in 2000-2999)
- **AND** the uid SHALL be recorded in the tray's per-session state

#### Scenario: proxy uid is outside the forge range

- **WHEN** the proxy distro starts tinyproxy
- **THEN** the uid that owns the listening socket SHALL be ≥1000 and SHALL NOT be in 2000-2999

## Sources of Truth

- `cheatsheets/runtime/wsl-on-windows.md` — operational mapping of "podman image on Linux = WSL distro on Windows"; defines uid-range convention and smoke-probe expectations.
- `docs/cheatsheets/runtime/wsl/architecture-isolation.md` — Microsoft Learn quote establishing that all WSL2 distros share one Linux network namespace; this is the constraint that motivates Layer 1's uid-based scope.
- `docs/cheatsheets/runtime/wsl/cli-surface.md` — `wsl --user`, `wsl --exec` invocation forms used by the tray.
