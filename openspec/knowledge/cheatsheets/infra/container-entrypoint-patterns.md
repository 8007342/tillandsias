# Container Entrypoint Patterns

## Architecture

- Modular dispatch: one entrypoint script per container type, selected via `--entrypoint`
- Shared library: `lib-common.sh` sourced by all entrypoints — never executed directly
- Deprecated redirect: `entrypoint.sh` dispatches to per-type scripts via `TILLANDSIAS_AGENT` / `TILLANDSIAS_MAINTENANCE` env vars
- Rust-side: `ContainerProfile.entrypoint` field (absolute path in-container) selects which script runs
- Scripts installed to `/usr/local/bin/` inside the image; `lib-common.sh` at `/usr/local/lib/tillandsias/lib-common.sh`

## Entrypoint Types

| Script | Profile fn | Purpose | Secrets |
|---|---|---|---|
| `entrypoint-forge-claude.sh` | `forge_claude_profile()` | Claude Code + OpenSpec | `~/.claude/` (OAuth), gh, git |
| `entrypoint-forge-opencode.sh` | `forge_opencode_profile()` | OpenCode + OpenSpec | gh, git only |
| `entrypoint-terminal.sh` | `terminal_profile()` | Interactive fish shell (maintenance) | gh, git only |
| `entrypoint.sh` | (deprecated) | Legacy redirect for cached images | delegates |

## Shared Library (lib-common.sh)

- `umask 0022` — ensures bind-mounted files are user-writable on host
- `trap 'exit 0' SIGTERM SIGINT` — clean container shutdown
- Locale detection: `LC_ALL > LC_MESSAGES > LANG > LANGUAGE`, sources `/etc/tillandsias/locales/<lang>.sh`
- `~/.config/gh` mkdir + `~/.gitconfig` touch — secret dir scaffolding
- `gh auth setup-git` — registers gh as git credential helper (non-fatal if gh absent)
- Shell config deployment: copies `/etc/skel/` files (`.bashrc`, `.zshrc`, `config.fish`) to `$HOME` if not present
- `CACHE="$HOME/.cache/tillandsias"` — canonical persistent cache path
- `export PATH="$CACHE/openspec/bin:$HOME/.local/bin:$PATH"` — makes cached tools available
- `needs_update_check(stamp_file)` — returns 0 if last check was >24h ago or never ran
- `record_update_check(stamp_file)` — writes current epoch to stamp file
- `find_project_dir()` — sets `$PROJECT_DIR` to first directory under `~/src/`
- `show_banner(agent_name)` — prints locale-aware forge/project/agent banner

## Lifecycle Pattern

Each agent entrypoint follows this sequence:

```
source lib-common.sh
  → umask, trap, locale, gh auth, shell configs, PATH, CACHE

install agent (cached under $CACHE/)
  → skip if binary exists

update agent (daily throttle via stamp file)
  → npm view / official installer check, upgrade if version differs

install OpenSpec (cached under $CACHE/openspec/)
  → npm install -g --prefix $CACHE/openspec @fission-ai/openspec

find_project_dir → cd $PROJECT_DIR

openspec init (first launch only, if $PROJECT_DIR/openspec/ absent)
  → openspec init --tools <agent>

show_banner "<agent>"

exec <agent binary> "$@"
  → on failure: print diagnostic and exec bash
```

Terminal entrypoint is simpler: source common → find project → show welcome → export `TILLANDSIAS_WELCOME_SHOWN=1` → exec fish (fallback bash).

## Agent Cache Locations

- Claude Code: `$CACHE/claude/` — installed via `npm install -g --prefix`; binary at `$CACHE/claude/bin/claude`
- OpenCode: `$CACHE/opencode/` — installed via official installer (`OPENCODE_INSTALL_DIR=$CACHE/opencode curl -fsSL https://opencode.ai/install | bash`)
- OpenSpec: `$CACHE/openspec/` — installed via `npm install -g --prefix`; binary at `$CACHE/openspec/bin/openspec`
- Stamp files: `$CACHE/<agent>/.last-update-check` — epoch timestamp for daily throttle

The cache dir is a bind mount from the host (`~/.cache/tillandsias`), so installs persist across container restarts.

## Embedding in Binary (embedded.rs)

- All scripts embedded at compile time via `include_str!()` — closes supply-chain gap vs unsigned `~/.local/share/` files
- Extracted to `$XDG_RUNTIME_DIR/tillandsias/image-sources/` (RAM-backed, per-session) via `write_image_sources()`
- Written into the image during `nix build` / `flake.nix` build
- `write_temp_script(name, content)` — writes a single script with `0700` permissions to the runtime temp dir
- `cleanup_image_sources()` — removes extracted tree after build completes

Key constants in `embedded.rs`:
- `FORGE_LIB_COMMON`, `FORGE_ENTRYPOINT`, `FORGE_ENTRYPOINT_CLAUDE`, `FORGE_ENTRYPOINT_OPENCODE`, `FORGE_ENTRYPOINT_TERMINAL`

## Rust Profile → Entrypoint Mapping

`ContainerProfile.entrypoint` is the absolute in-container path passed as `--entrypoint` to podman:

```rust
forge_claude_profile()   → "/usr/local/bin/entrypoint-forge-claude.sh"
forge_opencode_profile() → "/usr/local/bin/entrypoint-forge-opencode.sh"
terminal_profile()       → "/usr/local/bin/entrypoint-terminal.sh"
web_profile()            → "/entrypoint.sh"  (different image)
```

Security flags (`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--rm`) are hardcoded in `build_podman_args()` and NOT part of the profile — they cannot be overridden by profile configuration.

## Welcome Banner Guard

- `entrypoint-terminal.sh` exports `TILLANDSIAS_WELCOME_SHOWN=1` before exec-ing fish
- `config.fish` checks `set -q TILLANDSIAS_WELCOME_SHOWN` — skips its own welcome block if set
- This prevents the banner from displaying twice when fish sources its config on startup
- Agent entrypoints (`entrypoint-forge-claude.sh`, `entrypoint-forge-opencode.sh`) call `show_banner` directly and do not export the guard — fish does not display a banner in those non-interactive sessions

## Security

- Claude entrypoint: mounts `~/.claude/` (OAuth dir) as `rw`; no `CLAUDE_API_KEY` in env
- OpenCode entrypoint: no Claude secrets; no `~/.claude/` mount
- Terminal entrypoint: no agent secrets at all; gh and git credentials only
- `entrypoint.sh` (legacy): reads `TILLANDSIAS_AGENT` and `TILLANDSIAS_MAINTENANCE` env vars to dispatch — no secrets of its own
- Secret mount defined as `SecretKind::ClaudeDir` in `ContainerProfile.secrets`; absent from opencode and terminal profiles

## Known Pitfalls

- `lib-common.sh` must never contain `exit` or `exec` — it is sourced, not executed; either would terminate the calling entrypoint
- Update check stamp files live inside the agent cache prefix — if cache is wiped, the next launch will always attempt an update check
- `find_project_dir` picks the first alphabetical entry under `~/src/` — watch-root containers bind-mount the watch root at `~/src/` directly, so this resolves correctly
- `openspec init` is skipped if `$PROJECT_DIR/openspec/` already exists — re-initialization requires manual removal
