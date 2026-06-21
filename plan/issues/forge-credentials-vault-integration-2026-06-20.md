# Forge Vault Credential Integration — Design & Packets

**Filed:** 2026-06-20T17:15Z
**Origin:** Forge container, research session
**Agent:** forge-agent inside tillandsias-forge-base
**Host:** MacBookAir6,2 (i7-4650U, 8GB) — Fedora 44 container
**Trace:** `spec:secrets-management`, `spec:forge-offline`, `spec:env-bootstrap`

---

## Research Summary

### Vault Architecture

Vault runs as a Podman container (`tillandsias-vault`) on the Linux host:
- **Enclave address:** `https://vault:8200`
- **Host loopback:** `https://127.0.0.1:8201`
- **Auth:** AppRole (short-lived tokens, 1h TTL, single-use Secret IDs)
- **Secrets engine:** KV v2 at `secret/`
- **Policies:** `git-mirror-policy`, `forge-policy`, `tray-policy`, `inference-policy`, `github-login-policy`

### Existing Credential Flow (GitHub — Canonical Pattern)

1. **First launch:** `tillandsias --github-login` → one-shot container → user pastes token → stored at `secret/github/token`
2. **Runtime use:** git post-receive hook reads Vault via AppRole token → injects `https://oauth2:<TOKEN>@github.com/...` into push URL
3. **Token NEVER leaves container** at any step — host only holds short-lived AppRole tokens

### Current Agent Auth Status

| Agent | Auth method | Forge support | Vault integration |
|-------|-------------|---------------|-------------------|
| Claude Code | `ANTHROPIC_API_KEY` env var or `~/.claude/` OAuth | ❌ credential-free per spec | ❌ none |
| OpenAI Codex | `OPENAI_API_KEY` env var | ❌ credential-free per spec | ❌ none |
| Antigravity (`agy`) | Presumably `ANTHROPIC_API_KEY` or `GEMINI_API_KEY` | ❌ not in forge image at all | ❌ none |
| OpenCode | API key in config.json for inference providers | ⚠️ ollama works (local), remote needs key | ❌ none |

### Proxy Architecture

Squid `tillandsias-proxy` runs MITM SSL bump on ports 3128/3129. Has **no credential injection** — it's a transparent caching proxy. All API calls from forge go through it with the allowlist at `images/proxy/allowlist.txt`.

---

## Design: Vault-Based Credential Injection for Agents

### Architecture

```
User runs: tillandsias --claude-login
  └─ Launches one-shot container with AppRole lease
      └─ User pastes ANTHROPIC_API_KEY
          └─ Container writes to vault: secret/anthropic/token
              └─ Container exits, lease revoked

User runs: tillandsias . --claude
  └─ Tray reads vault: secret/anthropic/token
      └─ Tray adds -e ANTHROPIC_API_KEY=<token> to podman run
          └─ Forge container starts with ANTHROPIC_API_KEY set
              └─ Claude Code finds auth, skips login prompt
```

### New Vault Paths

| Path | Content | Policy | Purpose |
|------|---------|--------|---------|
| `secret/anthropic/token` | `ANTHROPIC_API_KEY` | `anthropic-policy` | Claude Code auth |
| `secret/openai/token` | `OPENAI_API_KEY` | `openai-policy` | OpenAI Codex auth |
| `secret/antigravity/token` | API key for agy | `antigravity-policy` | Antigravity CLI auth |

### Vault Policies

```hcl
# anthropic-policy
path "secret/data/anthropic/token" {
  capabilities = ["read", "create", "update"]
}
# Same pattern for openai-policy, antigravity-policy
```

### AppRole Roles

- `anthropic-login`: write `secret/anthropic/token` (for login containers)
- `openai-login`: write `secret/openai/token` (for login containers)
- `antigravity-login`: write `secret/antigravity/token` (for login containers)
- `forge-credential-agent`: read `secret/anthropic/token`, `secret/openai/token`, `secret/antigravity/token` (for tray)

---

## Action Packets

### Packet A: Add vault policies and AppRole roles for agent credentials

- id: `forge-credentials/vault-policies`
- severity: high
- owner_host: linux
- capability_tags: [rust, vault, containers, tray]
- source: `plan/issues/forge-credentials-vault-integration-2026-06-20.md`
- next_action: Add ACL policies `anthropic-policy`, `openai-policy`, `antigravity-policy` in the vault bootstrap code. Add AppRole roles for each. Ensure `forge-policy` (or new `forge-credential-agent` role) can read these paths.
- owned_files:
  - `crates/tillandsias-headless/src/vault_bootstrap.rs`
  - `images/vault/` (if vault config files)
- evidence_required:
  - Vault boots with new policies and roles
  - `forge-credential-agent` AppRole can read `secret/anthropic/token` after login
  - `anthropic-login` AppRole can write `secret/anthropic/token` and then it's readable
  - All existing vault tests pass

---

### Packet B: Create `tillandsias --anthropic-login` CLI subcommand (Claude Code auth)

- id: `forge-credentials/claude-login-command`
- severity: high
- owner_host: linux
- capability_tags: [rust, vault, cli, containers]
- source: `plan/issues/forge-credentials-vault-integration-2026-06-20.md`
- next_action: Build `tillandsias --anthropic-login` following the same pattern as `--github-login`:
  1. Validate vault is running
  2. Launch one-shot container with `anthropic-login` AppRole lease
  3. Prompt user to paste ANTHROPIC_API_KEY
  4. Write to `secret/anthropic/token` via vault-cli
  5. Verify round-trip read
  6. Exit, revoke lease
  7. Mirror in the tray UI.
- owned_files:
  - `crates/tillandsias-headless/src/main.rs` (new `--anthropic-login` arg)
  - `crates/tillandsias-headless/src/vault_bootstrap.rs` (AppRole minting for login)
- evidence_required:
  - `tillandsias --anthropic-login` prompts user, stores token, exits clean
  - Token is readable immediately after from vault
  - Login container gets correct vault network access (dual-homed if needed for API verification)
  - `tillandsias --help` shows the new option

---

### Packet C: Create `tillandsias --openai-login` CLI subcommand (Codex auth)

- id: `forge-credentials/codex-login-command`
- severity: high
- owner_host: linux
- capability_tags: [rust, vault, cli, containers]
- source: `plan/issues/forge-credentials-vault-integration-2026-06-20.md`
- next_action: Build `tillandsias --openai-login` following the same pattern as Packet B, storing at `secret/openai/token`.
- owned_files:
  - `crates/tillandsias-headless/src/main.rs`
  - `crates/tillandsias-headless/src/vault_bootstrap.rs`
- evidence_required:
  - Same as Packet B for OpenAI token

---

### Packet D: Create `tillandsias --antigravity-login` CLI subcommand (Antigravity auth)

- id: `forge-credentials/antigravity-login-command`
- severity: high
- owner_host: linux
- capability_tags: [rust, vault, cli, containers]
- source: `plan/issues/forge-credentials-vault-integration-2026-06-20.md`
- next_action: Build `tillandsias --antigravity-login` following the same pattern, storing at `secret/antigravity/token`. Determine which API key Antigravity uses (ANTHROPIC_API_KEY or GEMINI_API_KEY based on its backend config).
- owned_files:
  - `crates/tillandsias-headless/src/main.rs`
  - `crates/tillandsias-headless/src/vault_bootstrap.rs`
- evidence_required:
  - Same as Packet B for Antigravity token
  - Antigravity CLI docs checked for env var name

---

### Packet E: Inject vault credentials into forge container env on launch

- id: `forge-credentials/inject-from-vault`
- severity: high
- owner_host: linux
- capability_tags: [rust, vault, podman, tray]
- source: `plan/issues/forge-credentials-vault-integration-2026-06-20.md`
- next_action: Modify `build_forge_agent_run_args` in `crates/tillandsias-headless/src/main.rs` to:
  1. Before launching forge container, check vault for `secret/anthropic/token`, `secret/openai/token`, `secret/antigravity/token`
  2. For each found token, add `-e ANTHROPIC_API_KEY=<value>` (or equivalent) to the podman run args
  3. The env var is visible inside the forge container automatically
  4. Claude/Codex/Antigravity SDKs pick it up from their standard env var
  5. Respect per-agent injection: Claude gets ANTHROPIC_API_KEY, Codex gets OPENAI_API_KEY
- owned_files:
  - `crates/tillandsias-headless/src/main.rs` (build_forge_agent_run_args)
  - `crates/tillandsias-vault-client/src/lib.rs` (new read methods)
- evidence_required:
  - Forge container launched with `--claude` has `ANTHROPIC_API_KEY` env var set
  - Forge container launched with `--codex` has `OPENAI_API_KEY` env var set
  - Forge container launched without credential injection has no API key env vars (backward compat)
  - If vault is down or token missing, container launches without API key (graceful degradation)
  - Token values are not logged in debug output

---

### Packet F: Add vault availability probe to entrypoints for credential feedback

- id: `forge-credentials/vault-probe-entrypoint`
- severity: medium
- owner_host: linux
- capability_tags: [shell, entrypoints, vault]
- source: `plan/issues/forge-credentials-vault-integration-2026-06-20.md`
- next_action: Modify entrypoints (`entrypoint-forge-claude.sh`, `entrypoint-forge-codex.sh`, and a new `entrypoint-forge-antigravity.sh`) to:
  1. On startup, check if the relevant API key env var is set (from vault injection)
  2. If set, log "credentials: authenticated via vault" (trace)
  3. If not set, log "credentials: not configured — login with `tillandsias --<agent>-login`" (welcome hint)
  4. Add to forge-welcome.sh a credential status line (e.g., "Claude Code: authenticated" or "Claude Code: not configured")
- owned_files:
  - `images/default/entrypoint-forge-claude.sh`
  - `images/default/entrypoint-forge-codex.sh`
  - `images/default/forge-welcome.sh`
  - `images/default/lib-common.sh`
- evidence_required:
  - Entrypoint logs credential status at startup
  - Forge welcome banner shows credential status per agent
  - No regression when vault is unreachable (graceful fallback to "not configured")

---

### Packet G: Create entrypoint-forge-antigravity.sh and add Antigravity CLI to forge image

- id: `forge-credentials/antigravity-entrypoint-and-image`
- severity: medium
- owner_host: linux
- capability_tags: [shell, entrypoints, dnf, containers]
- source: `plan/issues/forge-credentials-vault-integration-2026-06-20.md`
- next_action: 
  1. Add `antigravity` (`agy`) CLI to the forge image (Containerfile or as a cargo tool install)
  2. Create `entrypoint-forge-antigravity.sh` following the pattern of `entrypoint-forge-claude.sh`
  3. Add to `Containerfile` COPY/chmod block
  4. Add `antigravity` to the welcome banner tool listing
- owned_files:
  - `images/default/entrypoint-forge-antigravity.sh` (new)
  - `images/default/Containerfile.base` (install agy binary)
  - `images/default/Containerfile` (copy entrypoint)
  - `images/default/forge-welcome.sh`
- evidence_required:
  - `agy --help` works inside the forge image
  - Entrypoint starts antigravity with project context
  - Welcome banner includes antigravity in the agents list

---

### Packet H: Forge runner host type in meta-orchestration

- id: `forge-runner/host-type`
- severity: medium
- owner_host: linux
- capability_tags: [methodology, orchestration, forge]
- source: `plan/issues/forge-credentials-vault-integration-2026-06-20.md`
- next_action: Add `forge_runner` as a host kind in meta-orchestration and advance-work-from-plan:
  - Detection: `[ -n "$TILLANDSIAS_FORGE" ]` or `/run/.containerenv` exists
  - Capabilities: `shell`, `docs`, `read_plan`, `write_plan`, `edit_crates`, `edit_images`, `edit_scripts`, `edit_openspec`
  - Limitations: NO `podman`, NO `cargo test` (no full build), NO `cargo build`
  - Write scope: same as cross-host shared scope (`crates/`, `images/`, `openspec/`, `methodology/`, `plan/`, `scripts/`)
  - E2E gates: NONE (forge has no podman/outside access)
  - The forge runner should be listed in meta-orchestration's "Worker Drain" phase: after host-based workers complete, meta-orchestration on linux_mutable should consider whether to launch a forge worker for forge-specific work
- owned_files:
  - `.opencode/skills/meta-orchestration/SKILL.md`
  - `.opencode/skills/advance-work-from-plan/SKILL.md`
  - `methodology/multi-host-development.yaml` (if forge runner becomes a permanent host kind)
- evidence_required:
  - `forge_runner` is detected and classified correctly
  - Plan packets owned by `forge_runner` are claimable from within the forge
  - Meta-orchestration does NOT try to run podman or e2e gates on a forge runner

---

### Packet I: E2E test meta-orchestration integration

- id: `e2e/meta-orchestration-integration`
- severity: medium
- owner_host: linux
- capability_tags: [testing, orchestration, forge, e2e]
- source: `plan/issues/forge-credentials-vault-integration-2026-06-20.md`
- next_action: Modify local-build and curl-install E2E test flows to:
  1. After successful forge launch, run `/meta-orchestration` skill inside the forge
  2. The in-forge agent records findings as plan packets under `plan/issues/`
  3. The agent pushes its findings to `origin/linux-next` (via git-service)
  4. After E2E test completes, check for new plan packets from the forge agent
  5. Include any forge findings in the E2E evidence bundle
- This creates a virtuous cycle: E2E tests validate the forge, and the forge self-documents issues it discovers
- owned_files:
  - `skills/build-install-and-smoke-test-e2e/SKILL.md`
  - `skills/smoke-curl-install-and-test-e2e/SKILL.md`
  - `scripts/local-ci.sh` or equivalent test harness
- evidence_required:
  - E2E test passes AND generates forge findings
  - Findings are committed to `linux-next` by the in-forge agent
  - E2E fails if forge findings indicate critical or high issues
  - E2E passes with findings-only (non-critical issues documented, not blocking)

---

### Packet J: OpenCode forge config tuning for credential integration

- id: `forge-credentials/opencode-config-tune`
- severity: low
- owner_host: linux
- capability_tags: [opencode, config, forge]
- source: `plan/issues/forge-credentials-vault-integration-2026-06-20.md`
- next_action: Tune the forge's opencode config at `config-overlay/opencode/config.json` for vault credential integration:
  1. Add an MCP tool `vault-credentials` that can check if agent credentials are stored in vault
  2. Add instructions for the agent to check credential status and prompt user to run `tillandsias --<agent>-login` when needed
  3. Consider adding a new provider config that reads API keys from env vars (already standard for most providers)
  4. Update `methodology.md` instruction to mention credential management
- owned_files:
  - `images/default/config-overlay/opencode/config.json`
  - `images/default/config-overlay/opencode/instructions/methodology.md`
  - `images/default/config-overlay/mcp/` (new vault-credentials MCP tool)
- evidence_required:
  - OpenCode agent can check credential status via MCP
  - Agent instructions mention vault-based credential flow
  - No API keys stored in config.json (env var only)

---

### Packet K: Tune forge container resource limits and performance

- id: `forge-tune/resource-limits-and-performance`
- severity: low
- owner_host: linux
- capability_tags: [rust, podman, containers, tray]
- source: `plan/issues/forge-diagnostics-audit-2026-06-20.md`
- next_action:
  1. Add `--memory=6g --cpus=3` to forge container launch args in `build_opencode_forge_args` / `build_forge_agent_run_args` in `main.rs`
  2. Add `TILLANDSIAS_IMAGE_VERSION` env var at launch time (image version from VERSION file or build arg)
  3. Add `/etc/tillandsias-version` to the Containerfile build (version marker)
  4. Verify `tillandsias-inventory` shows the version instead of "vunset"
- owned_files:
  - `crates/tillandsias-headless/src/main.rs`
  - `images/default/Containerfile.base`
  - `images/default/Containerfile`
- evidence_required:
  - Forge container has memory.max < host total (6g)
  - Forge container has CPU quota set (3 cpus)
  - `cat /etc/tillandsias-version` returns a version string
  - `tillandsias-inventory` shows the version

---

### Packet L: Add `antigravity` agent to welcome banner and tools listing

- id: `forge-credentials/antigravity-welcome-integration`
- severity: low
- owner_host: linux
- capability_tags: [shell, forge, welcome]
- source: `plan/issues/forge-credentials-vault-integration-2026-06-20.md`
- next_action: Add `agy` (Antigravity CLI) to the forge welcome banner tool listing section, alongside the existing agents. Add a tip about `agy` in the rotating tips. The welcome banner currently lists agents in the "Tool inventory" section but antigravity is not shown.
- owned_files:
  - `images/default/forge-welcome.sh`
- evidence_required:
  - Welcome banner lists "agy" or "Antigravity" in the agent listing
  - Rotating tips occasionally show antigravity-related tip

---

## Discovery: Antigravity CLI

Antigravity is the project-internal name for an AI agent CLI whose binary is `agy`. It is used in the `repeat` script (repo root, line 271-275):

```bash
antigravity)
    ANTIGRAVITY_BIN="${ANTIGRAVITY_BIN:-agy}"
    run_in_pty env "$ANTIGRAVITY_BIN" --print "$PROMPT" \
        --dangerously-skip-permissions --add-dir "$REPO_ROOT"
```

It is invoked similarly to `claude`, `opencode`, `codex`, and `gemini` agents in the repeat loop. The binary name defaults to `agy`, overridable via `$ANTIGRAVITY_BIN` env var. The `repeat` script is a Bash harness that runs recurring AI agent sessions with PTY emulation and timeout.

Antigravity is referenced extensively in `plan/index.yaml` as agent IDs (`linux-tlatoani-fedora-antigravity-*`, `macos-tlatoani-antigravity-*`). It has a brain/storage directory at `/home/tlatoani/.gemini/antigravity/brain/` based on smoke-e2e findings files.

**Key observation:** Antigravity is NOT in the forge image. It's an external tool installed on the host (likely in `~/.gemini/antigravity/`). For forge credential integration, the `agy` binary must be added to the forge image, and its auth mechanism must be determined (likely `ANTHROPIC_API_KEY` or `GEMINI_API_KEY` based on its backend).

---

## Cross-Packet Dependencies

```
Packets A (vault policies) ──→ B, C, D (login commands) ──→ E (injection)
                                                        └─→ F (entrypoint probe)

Packet G (antigravity entrypoint) ──→ L (welcome integration)

Packet H (forge runner) ← independent, but informs all forge-origin work

Packet I (e2e meta-orch) ← independent, run after forge is stable

Packets J, K ← independent, can be done in parallel
```

Priority order for implementation: A → B → C → D → E → F → G → L → H → I → J → K

---

## Forge Image Builder Note

To support credential injection, the forge container launch flow needs a vault client that can read secrets before dispatching the container. The `forge-credential-agent` AppRole token must be available to the tray process. Currently the tray has `tray-policy` which can mint AppRole tokens but does not have a long-lived vault token. Approach:

1. At tray startup, mint `forge-credential-agent` AppRole token with 24h TTL
2. Store it as a podman secret (tmpfs)
3. Before launching any forge container, read vault for agent tokens
4. Inject as env vars into the podman run args

This follows the same pattern as `git-mirror`'s token handling.
