---
tags: [agents, codex, entrypoints, tray-launcher, environment]
languages: []
since: 2026-05-04
last_verified: 2026-05-04
sources:
  - https://github.com/8007342/tillandsias
authority: high
status: current
tier: bundled
summary_generated_by: implementation
bundled_into_image: true
committed_for_project: false
---

# Codex Agent Entrypoints

@trace spec:codex-tray-launcher @cheatsheet runtime/codex-agent-entrypoints.md

**Version baseline**: Tillandsias v0.1.170+
**Use when**: Launching Codex agent from tray menu, configuring environment variables, or invoking the codex binary from scripts.

## Provenance

- <https://github.com/8007342/tillandsias> — Tillandsias tray launcher and Codex integration
- **Last updated:** 2026-05-04

## Overview

Codex is a specialized AI agent invoked from the Tillandsias tray menu. It runs inside an inference container with access to local language models and forge state.

## Binary Path & Invocation

| Location | Context |
|----------|---------|
| `/opt/codex/bin/codex` | Inside forge container (baked at image build) |
| `tillandsias codex launch` | Tray subprocess call (Unix socket dispatch) |
| Menu: "Codex" (tray) | User-facing entry point |

## Bootstrap Command

| Command | Effect |
|---------|--------|
## Environment Variables

| Variable | Set By | Used For |
|----------|--------|----------|
| `CODEX_FORGE_NAME` | Tray handler | Current forge container name |
| `CODEX_PROJECT_ROOT` | Tray handler | Bind mount path (project directory) |
| `CODEX_MODEL_ENDPOINT` | Inference container | Ollama socket (via unix:///run/user/1000/ollama.sock) |
| `CODEX_LOG_LEVEL` | User config (~/.config/tillandsias/config.toml) | Debug/info/warn/error |

## Entrypoint Script

**Location**: `images/codex/entrypoint.sh`
**Called by**: Tray handler `launch_codex()` in `src-tauri/src/handlers.rs`

```bash
#!/usr/bin/env bash
set -eu
# @trace spec:codex-tray-launcher

# Read environment, validate model endpoint health, launch agent
export CODEX_READY=1
exec /opt/codex/bin/codex "$@"
```

## Tray Handler Flow

**File**: `src-tauri/src/handlers.rs`
**Annotation**: `// @trace spec:codex-tray-launcher`

1. User clicks "Codex" menu item
2. Tray calls `handle_codex_launch()`
3. Handler creates subprocess: `podman exec tillandsias-<project>-forge /entrypoint.sh`
4. Codex binary receives `CODEX_FORGE_NAME`, `CODEX_PROJECT_ROOT` env vars
5. Codex connects to inference container socket for model queries

## Sources of Truth

- `cheatsheets/runtime/agent-startup-skills.md` — Agent routing and skill dispatch patterns
- `cheatsheets/runtime/local-inference.md` — Ollama model endpoints and UNIX socket paths
