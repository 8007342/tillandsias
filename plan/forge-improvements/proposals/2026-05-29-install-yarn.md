---
title: Install yarn package manager for Node.js
gap: YARN_CACHE_FOLDER is exported in lib-common.sh but yarn is not installed in the forge image
category: runtime-tool
status: proposed
proposed_at: 2026-05-29T18:30:00Z
changes:
  - file: images/default/Containerfile
    description: Add `yarn` to the npm global install RUN layer (same layer as opencode-ai, claude-code, codex). YARN_CACHE_FOLDER is already exported by lib-common.sh routing yarn cache to the per-project cache.
approved_by: null
---

## Gap

The forge image exports `YARN_CACHE_FOLDER` (lib-common.sh:548) routing yarn's package cache to the per-project cache. However, no `yarn` CLI is installed in the image.

This means:

1. `YARN_CACHE_FOLDER` is a dead env var — agents who `cd` into a project with `yarn.lock` and run `yarn install` get `command not found`
2. `project-info.sh` (line 26) detects `yarn.lock` and labels the project `node-yarn`, but the agent can't run yarn
3. `dependency-resolver.sh` (lines 94-95) knows yarn as a package manager but can't invoke it
4. `forge-welcome.sh` (line 171) lists yarn as a build tool in the welcome banner
5. `tillandsias-inventory` (line 27) lists yarn under Build tools
6. `cache-discipline.md` documents the yarn cache path convention

Yarn is widely used in Node.js monorepos and is the default package manager for several frameworks (e.g., React Native). Without it, agents working on such projects are forced to switch to npm or fail.

## Evidence

- `images/default/lib-common.sh` line 548: `export YARN_CACHE_FOLDER="$PROJECT_CACHE/yarn"`
- `images/default/config-overlay/mcp/project-info.sh` line 26: `[ -f "$project_dir/yarn.lock" ] && types="$types node-yarn"`
- `images/default/config-overlay/mcp/dependency-resolver.sh` lines 94-95: yarn detection
- `images/default/forge-welcome.sh` line 171: lists yarn under Build
- `images/default/cli/tillandsias-inventory` line 27: lists yarn as expected Build tool
- `images/default/config-overlay/opencode/instructions/cache-discipline.md`: documents yarn cache path
- npm is already installed; `npm install -g yarn` is a standard install path

## Safety

- Yarn is installed via `npm install -g yarn` — same trusted npm registry used for opencode-ai, claude-code, codex
- YARN_CACHE_FOLDER already points to per-project cache
- No credentials or secrets are involved
- Yarn is a well-known, widely used package manager (1.2B+ monthly npm downloads)
