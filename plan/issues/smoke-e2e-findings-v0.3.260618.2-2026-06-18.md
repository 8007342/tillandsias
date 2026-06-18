# Smoke E2E Findings - Release v0.3.260618.2 - 2026-06-18

Discovered by `/smoke-curl-install-and-test-e2e`.

## Result: PASS with forge follow-up findings

The published Linux installer, destructive Podman reset, pristine init, and
prompted OpenCode forge lane all completed successfully for release
`v0.3.260618.2`.

The in-forge `/forge-continuous-enhancement` run filed three follow-up forge
improvement proposals and committed them as `62964f02`; the forge-side GitHub
mirror push failed because credentials are intentionally unavailable in the
enclave, then the host pushed `62964f02` to `origin/linux-next`.

### Evidence trail (`target/smoke-e2e/`)

- `01-install.log:15` - downloaded the published Linux artifact and verified
  its SHA256 checksum.
- `01-version.txt:1` - installed binary reports `Tillandsias v0.3.260618.2`.
- `02-ps.txt`, `02-volumes.txt`, `02-images.txt` - post-reset container,
  volume, and image inventories were empty.
- `03-init-exit.txt:1` - fresh init exited `0`.
- `03-init.log:3882` - forge image build completed.
- `03-init.log:3917` - web image build completed.
- `03-init.log:4016` - Vault reached healthy initialized/unsealed state.
- `03-init.log:4029` - Vault bootstrap completed with policies and AppRoles
  provisioned.
- `04-opencode-exit.txt:1` - prompted forge lane exited `0`.
- `04-opencode.log:228` - in-forge run filed three new gaps.
- `04-opencode.log:233` - in-forge commit was `62964f02`; host push to GitHub
  was completed after the forge credential-isolation warning.

### Notes

- Fresh init created the managed `tillandsias-egress` network before the
  internal `tillandsias-enclave` network and launched Vault cleanly.
- The forge entrypoint still logs the known non-blocking OpenSpec warning
  (`04-opencode.log:2`). This was already recorded in earlier smoke evidence;
  no duplicate packet is filed here.
- This smoke did not exercise `tillandsias --debug --github-login`, so the
  GitHub-login helper still needs an operator-attended token-paste runtime
  check with a fresh/rotated token.

### Work Packet: smoke-finding/forge-ripgrep-missing

- id: `smoke-finding/forge-ripgrep-missing`
- owner_host: linux
- capability_tags: [forge, runtime-tool, diagnostics, testing]
- status: done
- discovered_by: `/smoke-curl-install-and-test-e2e` on release
  `v0.3.260618.2`
- evidence:
  - `target/smoke-e2e/04-opencode.log:228` - in-forge run filed new gaps.
  - `plan/forge-improvements/proposals/2026-06-18-install-ripgrep.md` -
    detailed proposal for installing ripgrep.
  - `images/default/Containerfile.base:12` - ripgrep already installed via microdnf
  - `rg --version` - ripgrep 14.1.1 confirmed present at /usr/bin/rg
- repro:
  - Run `tillandsias . --opencode --prompt "Use the /forge-continuous-enhancement skill"` and inspect diagnostics proposal output.
- next_action: >
    FALSE POSITIVE — ripgrep is already installed. Update diagnostics prompt to stop reporting it as missing. No code changes needed.
- events:
  - type: discovered
    ts: "2026-06-18T20:50:00Z"
    agent_id: "linux-macuahuitl-codex-20260618T2038Z"
    host: linux
  - type: claim
    ts: "2026-06-18T21:18:47Z"
    agent_id: "linux-macuahuitl-opencode-big-pickle-20260618T211847Z"
    host: linux
    lease_id: "88f056653c52"
    expires_at: "2026-06-19T01:18:47Z"
  - type: completed
    ts: "2026-06-18T21:19:00Z"
    agent_id: "linux-macuahuitl-opencode-big-pickle-20260618T211847Z"
    host: linux
    lease_id: "88f056653c52"
    evidence_refs:
      - "images/default/Containerfile.base:12" -- ripgrep is already installed via microdnf
      - "rg --version" -- ripgrep 14.1.1 confirmed present at /usr/bin/rg
    note: "FALSE POSITIVE — ripgrep is already installed in the forge base image (Containerfile.base:12). The diagnostics agent incorrectly reported it as missing. No code changes needed."

### Work Packet: smoke-finding/forge-marksman-missing

- id: `smoke-finding/forge-marksman-missing`
- owner_host: linux
- capability_tags: [forge, runtime-tool, markdown, diagnostics]
- status: done
- discovered_by: `/smoke-curl-install-and-test-e2e` on release
  `v0.3.260618.2`
- evidence:
  - `target/smoke-e2e/04-opencode.log:228` - in-forge run filed new gaps.
  - `plan/forge-improvements/proposals/2026-06-18-install-marksman.md` -
    detailed proposal for adding a Markdown LSP server.
  - `images/default/Containerfile.base:37-38` - marksman installed from GitHub releases
- repro:
  - Run `tillandsias . --opencode --prompt "Use the /forge-continuous-enhancement skill"` and inspect diagnostics proposal output.
- next_action: >
    Verify marksman is functional in the forge after next image rebuild. Rerun forge diagnostics to confirm it's no longer reported as missing.
- events:
  - type: discovered
    ts: "2026-06-18T20:50:00Z"
    agent_id: "linux-macuahuitl-codex-20260618T2038Z"
    host: linux
  - type: claim
    ts: "2026-06-18T21:20:00Z"
    agent_id: "linux-macuahuitl-opencode-big-pickle-20260618T211847Z"
    host: linux
    lease_id: "lease-marksman-install-20260618T212000"
    expires_at: "2026-06-19T01:20:00Z"
  - type: completed
    ts: "2026-06-18T21:22:00Z"
    agent_id: "linux-macuahuitl-opencode-big-pickle-20260618T211847Z"
    host: linux
    lease_id: "lease-marksman-install-20260618T212000"
    evidence_refs:
      - "images/default/Containerfile.base:37-38" -- marksman installed from GitHub release
      - "plan/forge-improvements/proposals/2026-06-18-install-marksman.md" -- proposal updated with implementation details
    note: "Installed marksman Markdown LSP server in Containerfile.base. Pinned to version 2026-02-08 (latest). Single binary at /usr/local/bin/marksman. Verifiable at next forge image rebuild."

### Work Packet: smoke-finding/forge-nix-store-missing

- id: `smoke-finding/forge-nix-store-missing`
- owner_host: linux
- capability_tags: [forge, runtime-tool, nix, diagnostics]
- status: done
- discovered_by: `/smoke-curl-install-and-test-e2e` on release
  `v0.3.260618.2`
- evidence:
  - `target/smoke-e2e/04-opencode.log:228` - in-forge run filed new gaps.
  - `plan/forge-improvements/proposals/2026-06-18-provision-nix-store.md` -
    detailed proposal for reconciling Nix instructions and `/nix/store`.
  - `images/default/config-overlay/opencode/instructions/nix-first.md` -
    updated to remove misleading forge-side nix claims, clarify nix is host-only.
  - `rg TILLANDSIAS_SHARED_CACHE` — env var does not exist in any source file
- repro:
  - Run `tillandsias . --opencode --prompt "Use the /forge-continuous-enhancement skill"` and inspect diagnostics proposal output.
- next_action: >
    CLARIFIED — nix is host-side only by design. The forge container does not
    need nix. nix-first.md was corrected to remove misleading claims about
    forge-side nix installation and /nix/store mounting.
    TILLANDSIAS_SHARED_CACHE does not exist in the codebase.
- events:
  - type: discovered
    ts: "2026-06-18T20:50:00Z"
    agent_id: "linux-macuahuitl-codex-20260618T2038Z"
    host: linux
  - type: claim
    ts: "2026-06-18T21:25:00Z"
    agent_id: "linux-tlatoani-opencode-big-pickle-20260618T212500Z"
    host: linux
    lease_id: "lease-nix-store-clarify-20260618T212500"
    expires_at: "2026-06-19T01:25:00Z"
  - type: completed
    ts: "2026-06-18T21:28:00Z"
    agent_id: "linux-tlatoani-opencode-big-pickle-20260618T212500Z"
    host: linux
    lease_id: "lease-nix-store-clarify-20260618T212500"
    evidence_refs:
      - "images/default/config-overlay/opencode/instructions/nix-first.md" -- corrected nix documentation (forge-side vs host-side)
      - "plan/forge-improvements/proposals/2026-06-18-provision-nix-store.md" -- updated resolution section
      - "rg TILLANDSIAS_SHARED_CACHE" -- env var not present in any source file
    note: "CLARIFIED — nix is host-side only by design. nix-first.md was updated to remove misleading claims about nix being in the container. TILLANDSIAS_SHARED_CACHE does not exist. No code changes needed; documentation drift fixed."

### Event

- type: run
  ts: "2026-06-18T20:50:00Z"
  agent_id: "linux-macuahuitl-codex-20260618T2038Z"
  host: linux
  release: "v0.3.260618.2"
  outcome: pass_with_findings
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
    - "plan/forge-improvements/proposals/2026-06-18-install-ripgrep.md"
    - "plan/forge-improvements/proposals/2026-06-18-install-marksman.md"
    - "plan/forge-improvements/proposals/2026-06-18-provision-nix-store.md"
