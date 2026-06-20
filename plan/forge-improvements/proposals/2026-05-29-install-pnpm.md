---
title: Install pnpm package manager for Node.js
gap: PNPM_HOME is exported in lib-common.sh but pnpm is not installed in the forge image
category: runtime-tool
status: proposed
proposed_at: 2026-05-29T18:00:00Z
changes:
  - file: images/default/Containerfile
    description: Add `pnpm` installation via npm i -g pnpm in the agent binaries RUN layer. PNPM_HOME is already exported by lib-common.sh routing pnpm store and global bins to the per-project cache.
approved_by: null
---

## Gap

The forge image exports `PNPM_HOME` (lib-common.sh:551) routing pnpm's global bin directory and store to the per-project cache. The `$PNPM_HOME` directory is also added to `$PATH` (lib-common.sh:561). However, pnpm itself is not installed.

pnpm is increasingly the default Node.js package manager for:
1. **Monorepo workflows**: pnpm workspaces are the de facto standard for modern monorepos
2. **Disk-efficient builds**: pnpm's content-addressable store saves significant space in CI
3. **Agent-driven development**: agents building Node.js projects in monorepos expect pnpm to be available
4. **Framework compatibility**: Next.js, Nuxt, Turborepo, and nx all recommend or default to pnpm

npm is installed (Containerfile line 22) and can install pnpm globally.

## Evidence

- `images/default/lib-common.sh` line 551: `export PNPM_HOME="$PROJECT_CACHE/pnpm"`
- `images/default/lib-common.sh` line 561: `export PATH="...:$PNPM_HOME:$PATH"`
- `images/default/Containerfile` line 22: `nodejs npm` installed but no pnpm
- pnpm is installable via `npm i -g pnpm` (~20 MB with dependencies)

## Safety

- pnpm is installed via npm from the npm registry — same trusted channel as the existing agent binaries (opencode, claude-code, codex).
- PNPM_HOME already points to per-project cache; pnpm store and global bins will be stored there.
- No additional network routes, credentials, or secrets are involved.
