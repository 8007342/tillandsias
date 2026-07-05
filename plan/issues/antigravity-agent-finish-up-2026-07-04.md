# Impl: finish the Antigravity (agy) forge agent — 2026-07-04

- class: enhancement (forge agent)
- filed: 2026-07-04
- owner: linux (or the Antigravity forge agent itself)
- status: ready
- trace: images/default/entrypoint-forge-antigravity.sh, ForgeAgentMode::Antigravity
- context: the Antigravity agent wired `agy` into the tray UX to launch its own harness
  but ran out of tokens mid-task; the WIP was recovered + compile-completed (commit
  35ba3d3f). This packet closes the remaining gaps.

## Already DONE (recovered + verified — do NOT redo)
- `--antigravity` CLI flag → `ForgeAgentMode::Antigravity` →
  `entrypoint-forge-antigravity.sh` → `exec agy`. Tray leaf (menu 6→7), LaunchKind,
  LeafAction, dispatch. `build_forge_agent_run_args` maps Antigravity → Gemini API key.
- `--antigravity-login` → generic token-paste flow → vault `secret/antigravity/oauth`;
  `ensure_provider_auth(Antigravity)` gates the launch on a saved token (Antigravity
  oauth + Gemini key), mirroring Codex/Claude.
- `entrypoint-forge-antigravity.sh` is complete (lib-common lifecycle, CA trust,
  clone, git identity, startup context, banner, `exec agy`).
- `agy` installed in `Containerfile.base` (antigravity.google CLI installer).
- Verified: `cargo build --features vault,tray` green, 244 headless tests pass, the
  7-leaf tray test passes.

## Remaining gaps to finish

1. **Forge-specific `agy` flags (LIKELY NEEDED — needs agy CLI docs).** The Codex
   entrypoint passes `--dangerously-bypass-approvals-and-sandbox` gated on
   `TILLANDSIAS_HOST_KIND=forge` (order 171) so the agent does not hang on approval /
   self-sandbox prompts inside the already-sandboxed forge. `entrypoint-forge-antigravity.sh`
   currently does a bare `exec agy "$@"`. Determine agy's equivalent non-interactive /
   bypass-sandbox flag from its CLI docs and add the same `HOST_KIND=forge`-gated
   pattern. DO NOT guess the flag — confirm it against `agy --help` / Antigravity docs.
2. **Verify the installer actually yields `/usr/local/bin/agy`.** The Containerfile
   does `ANTIGRAVITY_BIN=/usr/local/bin/agy … install.sh | bash`; confirm the installer
   honours `ANTIGRAVITY_BIN` and produces an executable named `agy` on PATH (else
   `exec agy` fails). Add a build-time or first-run `command -v agy` assertion.
   NOTE: per the CREATION→FIRST_RUN/EVERY_LAUNCH work (orders 180/181), `agy` should
   ultimately be installed EVERY_LAUNCH (latest) via order 181, not baked — reconcile
   there.
3. **Drift-protection test** (small, linux-doable now): assert
   `ForgeAgentMode::Antigravity.entrypoint() == "/usr/local/bin/entrypoint-forge-antigravity.sh"`
   and that `--antigravity` dispatches to it — mirrors the Codex/Claude coverage.
4. **E2E smoke (human-in-the-loop):** with a real Antigravity/Gemini credential,
   `tillandsias --antigravity-login` then `--antigravity <project>` reaches the model
   and runs a turn in the forge. Cannot be done autonomously (needs real creds); record
   evidence when run.

## Exit criteria
- agy launches non-interactively in the forge (no approval/sandbox hang) with the
  confirmed forge flag.
- `agy` presence is asserted (no silent `exec agy` failure).
- Drift test pins the Antigravity→entrypoint mapping.
- One human-in-the-loop e2e run recorded reaching the model through the proxy.
