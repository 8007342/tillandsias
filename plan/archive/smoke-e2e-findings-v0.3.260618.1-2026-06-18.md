# Smoke E2E Findings - Release v0.3.260618.1 - 2026-06-18

Discovered by `/smoke-curl-install-and-test-e2e`.

## Result: PASS end-to-end

The published Linux installer, destructive Podman reset, pristine init, and
prompted OpenCode forge lane all completed successfully for release
`v0.3.260618.1`.

### Evidence trail (`target/smoke-e2e/`)

- `01-install.log` - downloaded the published Linux artifact and verified its
  SHA256 checksum.
- `01-version.txt` - installed binary reports `Tillandsias v0.3.260618.1`.
- `02-ps.txt`, `02-volumes.txt`, `02-images.txt` - post-reset container,
  volume, and image inventories were empty.
- `03-init-exit.txt` - fresh init exited `0`.
- `03-init.log:4029` - Vault bootstrap completed with policies and AppRoles
  provisioned.
- `04-opencode-exit.txt` - prompted forge lane exited `0`.
- `04-opencode.log:109` - in-forge `/forge-continuous-enhancement` reported no
  new findings; diagnostics remained 25/25 with 100% completeness.

### Notes

- Fresh init created the managed `tillandsias-egress` network before the
  internal `tillandsias-enclave` network and launched Vault cleanly. This
  confirms the published release no longer reproduces the prior
  `smoke-finding/rootless-bridge-network-missing` forge-launch failure.
- The forge entrypoint still logs the known non-blocking OpenSpec warning
  (`04-opencode.log:3`). This was already recorded in
  `plan/issues/build-install-smoke-e2e-findings-2026-06-16.md`; no duplicate
  work packet was filed.
- This smoke did not exercise `tillandsias --debug --github-login`, so the
  GitHub-login helper egress regression still needs a targeted runtime check in
  a later gate.

### Event

- type: run
  ts: "2026-06-18T03:31:55Z"
  agent_id: "linux-macuahuitl-codex-20260618T0320Z"
  host: linux
  release: "v0.3.260618.1"
  outcome: pass
  evidence_refs:
    - "target/smoke-e2e/01-install.log"
    - "target/smoke-e2e/01-version.txt"
    - "target/smoke-e2e/02-ps.txt"
    - "target/smoke-e2e/02-volumes.txt"
    - "target/smoke-e2e/02-images.txt"
    - "target/smoke-e2e/03-init.log"
    - "target/smoke-e2e/03-init-exit.txt"
    - "target/smoke-e2e/04-opencode.log"
    - "target/smoke-e2e/04-opencode-exit.txt"
