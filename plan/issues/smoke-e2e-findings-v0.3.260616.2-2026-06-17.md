# Smoke E2E Findings - Release v0.3.260616.2 - 2026-06-17

Discovered by `/smoke-curl-install-and-test-e2e`.

Run summary: the published installer passed, the installed binary reported
`Tillandsias v0.3.260616.2`, and `podman system reset --force` left an empty
store. Fresh `tillandsias --debug --init` rebuilt all runtime images and
bootstrapped Vault successfully. The final OpenCode forge lane then failed
before starting the forge because the proxy spawn used
`--network tillandsias-enclave,bridge`, but the clean rootless Podman store had
no network named `bridge`.

## Result: HALTED at OpenCode forge launch

Init is healthy; the release-smoke failure is in the checkpointed
`enclave/network-level-egress-deny` implementation shipped in this release.
The dual-homing design assumes a Podman network named `bridge` exists. That
assumption is false on this clean Linux rootless runtime after
`podman system reset --force`.

### Evidence trail (`target/smoke-e2e/`)

- `01-version.txt` - installed binary reports `Tillandsias v0.3.260616.2`.
- `02-reset-verify.txt` - clean-room reset left no containers, volumes, or
  images.
- `03-init-exit.txt` - fresh init exited `0`.
- `03-init.log` - Vault reached `vault healthy (initialized=true sealed=false
  v=1.18.5)` and completed policy/AppRole bootstrap.
- `04-opencode.log:1` - OpenCode mode failed while starting `tillandsias-proxy`.
- `04-opencode.log:3` - proxy spawn command used
  `--network tillandsias-enclave,bridge`.
- `04-opencode.log:4` - Podman rejected the launch with
  `Error: unable to find network with name or ID bridge: network not found`.
- `04-opencode-exit.txt` - OpenCode smoke exited `1`.

### Work Packet: smoke-finding/rootless-bridge-network-missing

- id: `smoke-finding/rootless-bridge-network-missing`
- owner_host: linux
- capability_tags: [rust, podman, networking, enclave, release]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260616.2`
- related_packet: `enclave/network-level-egress-deny`
- severity: high - blocks the published Linux forge lane after a clean
  install/reset, so the network-level egress checkpoint cannot be accepted.
- evidence:
  - `target/smoke-e2e/04-opencode.log:3` - proxy launch uses
    `--network tillandsias-enclave,bridge`.
  - `target/smoke-e2e/04-opencode.log:4` - Podman reports
    `unable to find network with name or ID bridge`.
  - `target/smoke-e2e/03-init-exit.txt:1` - init itself was clean (`init exit: 0`),
    isolating the failure to the post-init forge/proxy launch path.
- repro:
  - `curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash`
  - `podman system reset --force`
  - `tillandsias --debug --init`
  - `tillandsias . --opencode --prompt "Use the /forge-continuous-enhancement skill"`
- next_action: >
    Replace the hard-coded `bridge` network assumption in the dual-homed
    proxy/git-service launch paths with a clean-rootless-safe egress network
    strategy. Either discover Podman's default rootless network name, create an
    explicit Tillandsias-managed external egress network during init, or attach
    the second leg using a supported Podman default that exists after reset.
    Then rerun the release smoke acceptance: clean init, direct enclave egress
    denied, proxy egress succeeds, git-mirror push works, and the OpenCode
    forge lane starts.
- events:
  - type: discovered
    ts: "2026-06-17T00:34:41Z"
    agent_id: "linux-tlatoani-codex-20260617T003441Z"
    host: linux
    release: "v0.3.260616.2"
    evidence_refs:
      - "target/smoke-e2e/04-opencode.log"
      - "target/smoke-e2e/04-opencode-exit.txt"

## Clean observations before the failure

- Published installer and checksum path succeeded.
- `podman system reset --force` was destructive and clean.
- Fresh init built all required images from an empty store and completed Vault
  bootstrap.
- The OpenCode prompt-consumption fix was not reached; failure occurred before
  OpenCode could start inside the forge container.
