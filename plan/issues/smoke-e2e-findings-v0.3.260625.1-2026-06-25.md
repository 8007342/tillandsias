# Curl-Install Smoke E2E Findings — v0.3.260625.1

- **Release tested**: `v0.3.260625.1` (published 2026-06-25)
- **Test date**: 2026-06-25T21:19Z
- **Host**: linux_immutable (`/run/ostree-booted`)
- **Branch**: `linux-next`
- **Agent**: big-pickle (meta-orchestration + smoke-curl-install-and-test-e2e)
- **Sibling heads**: `main@3ee4c2ae`, `linux-next@5cf56716`, `windows-next@a3c8b23d`, `osx-next@5cf56716`

## Result: PASS

All four stages completed cleanly on a pristine immutable-Linux host:

### Step 1 — curl-install
- Installed `Tillandsias v0.3.260625.1` via `install.sh` from latest GitHub release
- SHA256 checksum verified
- Binary placed at `~/.local/bin/tillandsias`

### Step 2 — destructive substrate reset
- `podman system reset --force` completed with no errors
- Store confirmed empty (0 containers, 0 volumes, 0 images)

### Step 3 — fresh `--debug --init`
- All images built from pristine state (proxy, git, inference, chromium-core, chromium-framework, forge-base, forge, zeroclaw, web, vault)
- Vault bootstrapped successfully: initialized, unsealed, 5 policies provisioned (GitMirror, Forge, Tray, Inference, GithubLogin)
- Exit code: 0

### Step 4 — forge continuous-enhancement run
- Forge launched inside enclave via `tillandsias . --opencode --prompt "Use the /forge-continuous-enhancement skill"`
- Agent audited forge state (25/25 diagnostics passing), closed `forge-build-telemetry` as done, filed `forge-diagnostics-prompt-cleanup`
- Committed and pushed to `linux-next` via git-mirror

### Work Packets Filed by Forge Agent
- `forge-diagnostics-prompt-cleanup-2026-06-25.md` — diagnostics runner should prune permanently-green checks
- `forge-build-telemetry-2026-06-20.md` — closed as done (all 3 telemetry slices confirmed)

### Logs
All logs preserved in `target/smoke-e2e/`:
- `01-install.log` / `01-version.txt`
- `02-reset.log`
- `03-init.log`
- `04-opencode.log`

---

*No release-blocking findings. Release v0.3.260625.1 is production-ready on Linux.*
