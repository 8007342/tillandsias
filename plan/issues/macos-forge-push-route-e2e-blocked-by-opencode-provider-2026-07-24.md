# E2E: macOS push-route fix DEPLOYED + forge builds/runs/clones with it; push blocked by OpenCode "No provider available"

- **Date:** 2026-07-24
- **Class:** e2e result + blocker (harness auth)
- **Area:** macOS forge push route (deployed) / OpenCode harness provider auth (blocker)
- **Status:** push-route fix DEPLOYED and exercised up to the harness; the actual `git push` is UNVERIFIED because OpenCode cannot run without a provider.
- **Owner:** OpenCode provider setup is operator-gated (needs a credential); the push-route fix is macOS/osx-next.

## What succeeded (the fix + infra work end-to-end up to the harness)

A headless `tillandsias-tray --opencode /Users/tlatoani/src/tillandsias` run produced:
- **The forge image rebuilt fresh with my fix**: `building missing image forge (localhost/tillandsias-forge:v0.3.260723.1)` — plus `forge-base`, `router`, `inference`, all at `v0.3.260723.1`. The version bump (my binary/project `0.3.260723.1` vs the cached `v0.3.260721.1`) forced the rebuild, so the built `forge` image contains my patched `images/default/lib-common.sh` (the push-URL routing).
- **VM booted, stack came up, forge launched, project cloned**: `Cloning into '/home/forge/src/tillandsias'... done`, then the forge banner (`project: tillandsias, agent: opencode`).
- So: the guest binary (with the `GIT_SERVICE` env fix), the forge-image rebuild (with the `lib-common.sh` push-URL fix), the stack bring-up, and the clone all work. The infra + fix are deployed and functioning up to the point the harness starts.

## What blocked the push (OpenCode has no LLM provider)

```
> build · big-pickle
Error: No provider available
Error: [OpenCode] forge session exited: stage 'opencode' attached command exited with status 1
```

- `entrypoint-forge-opencode.sh:80` calls `prepare_opencode_vault_auth` (reads the OpenCode provider credential from Vault) and `:81` `opencode_actual_auth_ok`. The forge configures OpenCode's provider from a **Gemini credential source** (`:77-79`) via Vault.
- The operator set up GitHub, Claude, and Codex logins but **not OpenCode's provider** ("trying opencode next"), so Vault has no OpenCode credential → **no provider** → OpenCode exits before it can run the push commands.
- **The push route itself was never exercised** — OpenCode never reached the `git push`. So the route is deployed but the end-to-end push is UNVERIFIED.

## Paths forward

1. **To reach the GOAL (OpenCode pushes):** set up OpenCode's provider (a login/credential — the Gemini source the entrypoint expects, or another provider). This is the harness-auth step and is the natural extension of the transparent harness-token work (`forge-claude-transparent-oauth-token-vault-inject-2026-07-23.md`) to OpenCode. **Operator-gated (needs a credential).**
2. **To independently VERIFY the push route without a provider:** drive a **Maintenance/terminal forge** (`ForgeAgentMode::Maintenance` → `entrypoint-terminal.sh`, `main.rs:10141` — a shell, no LLM) and run `git push` by hand. That entrypoint runs the same `clone_project_from_mirror` (my fix sets the push URL), so it exercises the route. **Gap: the macOS tray CLI exposes only `--opencode`, not a terminal/maintenance launch** — expose a headless terminal-forge verb (or a `tillandsias-headless` maintenance mode reachable via `--exec-guest`) to enable this. Worth a small packet.
3. **Alternate harness:** Claude/Codex are authed, but the macOS tray CLI cannot launch them headlessly (only `--opencode`). Same CLI-surface gap as #2.

## Notes

- `~/src/tillandsias` currently has my `images/default/lib-common.sh` applied to its working tree (dirty) as a **test-time deploy** — it was on `main` without the fix. The clean long-term path is the release pipeline merging `osx-next`→`main` so the forge project picks the fix up on `main`.
- The forge rebuild proves the version-tag rebuild path works: bump the project/binary version and the forge image rebuilds from the project's `images/default/`.

## Cross-references

- `plan/issues/macos-forge-push-route-slice1-implemented-2026-07-23.md` — the fix this deploys/exercises.
- `plan/issues/macos-forge-no-push-route-lane-decision-2026-07-23.md` — the P1 + Option B.
- `plan/issues/forge-claude-transparent-oauth-token-vault-inject-2026-07-23.md` — the harness-auth pattern OpenCode's provider needs.
- plan order 112 (forge-harness-auth-via-Vault).
