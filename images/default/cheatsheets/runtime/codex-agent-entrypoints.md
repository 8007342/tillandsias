---
tags: [agents, codex, claude, opencode, entrypoints, tray-launcher]
languages: [bash, rust]
since: 2026-05-04
last_verified: 2026-05-20
sources:
  - https://github.com/8007342/tillandsias
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# Forge Agent Entrypoints

@trace spec:codex-tray-launcher @trace spec:forge-as-only-runtime

**Use when**: Launching Codex, Claude, OpenCode, or the maintenance shell from
the tray or direct CLI flags.

## Current Contract

All agent CLIs run inside `tillandsias-forge:v<VERSION>`. The host never runs
`codex`, `claude`, or `opencode` directly.

| Mode | Direct CLI | Forge entrypoint | Binary inside forge |
|---|---|---|---|
| Codex | `tillandsias --codex <project> --debug` | `/usr/local/bin/entrypoint-forge-codex.sh` | `codex` |
| Claude | `tillandsias --claude <project> --debug` | `/usr/local/bin/entrypoint-forge-claude.sh` | `claude` |
| OpenCode TUI | `tillandsias --opencode <project> --debug` | `/usr/local/bin/entrypoint-forge-opencode.sh` | `opencode` |
| Maintenance | `tillandsias --bash <project> --debug` | `/usr/local/bin/entrypoint-terminal.sh` | `fish`, then `bash` if requested |

The tray path uses `launch_forge_agent()` to open the user's terminal emulator
and run the same forge image. Direct CLI flags attach the current terminal via
`run_forge_agent_cli_mode()`.

## Required Environment

Every host-mounted project launch must include:

```text
PROJECT=<project>
TILLANDSIAS_PROJECT=<project>
TILLANDSIAS_PROJECT_HOST_MOUNT=1
HOME=/home/forge
USER=forge
PATH=/usr/local/bin:/usr/bin
```

`TILLANDSIAS_PROJECT_HOST_MOUNT=1` is the safety latch. When it is set, shared
entrypoint code must `cd /home/forge/src/<project>` and skip mirror cloning.
It must not remove that directory; it is the user's real checkout.

Git identity is injected from GitHub Login as `GIT_AUTHOR_*` and
`GIT_COMMITTER_*`. The entrypoint writes repo-local `git config user.name` and
`user.email` after entering the project.

## Launch Diagnostics

With `--debug`, every stack stage emits compact launch events:

```text
[tillandsias] version: 0.2.260520.2
event:container_launch stage=forge-launch-proxy state=starting container=tillandsias-proxy
event:container_launch stage=codex state=starting container=tillandsias-myproj-forge detail=attached=true
```

Failure bodies should show:

1. failed stage and container
2. short cause
3. `next:` hint
4. redacted `podman run` argv

## Cleanup Rule

After an attached forge exits, the parent checks for active
`tillandsias-*-forge` containers. If none remain, it removes the project git
container plus shared proxy and inference containers. If another forge is still
active, shared services stay up.

## Verification

```bash
cargo test -p tillandsias-headless forge_agent_run_args_export_debug_when_requested -- --exact
cargo test -p tillandsias-headless forge_agent_run_argv_exports_project_selection -- --exact
scripts/local-ci.sh --phase runtime
```

## Sources of Truth

- `crates/tillandsias-headless/src/main.rs` —
  `ForgeAgentMode`, `run_forge_agent_cli_mode`, `launch_forge_agent`,
  `build_forge_agent_run_args`
- `images/default/lib-common.sh` — protected host-mount clone discipline
- `images/default/entrypoint-forge-codex.sh`
- `images/default/entrypoint-forge-claude.sh`
- `images/default/entrypoint-forge-opencode.sh`
- `images/default/entrypoint-terminal.sh`
