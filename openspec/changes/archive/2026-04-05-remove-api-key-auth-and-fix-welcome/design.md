## Context

Tillandsias currently has two Claude authentication paths: (1) API key via OS keyring injected as `ANTHROPIC_API_KEY` env var, and (2) OAuth via host `~/.claude/` directory mounted into the container. The API key path was the original implementation; OAuth was added later and is now the preferred path. Both coexist, with the API key taking precedence when present. The API key infrastructure spans 8+ files and adds unnecessary complexity.

The credential lifecycle should be: first launch -> Claude prompts for authentication -> user authenticates via browser -> credentials persist in `~/.claude/` -> subsequent launches find existing credentials and go straight to prompt. Reset is available via tray menu when needed.

## Goals / Non-Goals

**Goals:**
- Remove all API key infrastructure (keyring, prompt script, env var injection, handler)
- Claude authentication happens inside the container via Claude Code's own `claude login` flow
- Credentials persist across container launches via the `~/.claude/` mount
- Users can reset credentials from the tray menu (Seedlings > Claude Reset Credentials)
- Maintenance terminal shows welcome banner exactly once

**Non-Goals:**
- Changing the OAuth flow itself (that's Claude Code's responsibility)
- Adding credential status indicators beyond menu visibility
- Modifying the GitHub authentication flow (separate system, works fine)

## Decisions

**OAuth-only**: Claude Code handles its own authentication. The container mounts `~/.claude/` from the host. On first run, Claude prompts the user. On subsequent runs, it finds existing tokens. This is simpler, more secure (no env var exposure), and matches Claude Code's intended usage.

**Reset via directory cleanup**: "Claude Reset Credentials" removes the contents of `~/.claude/` on the host. This is safe because Claude Code recreates what it needs on next launch. The menu item only appears when `~/.claude/` exists and contains files.

**Welcome fix via environment variable**: `entrypoint-terminal.sh` exports `TILLANDSIAS_WELCOME_SHOWN=1` after displaying the banner. Fish's `config.fish` already checks this variable — it just wasn't being set by the entrypoint.

**Ensure ~/.claude/ always exists**: The launch context should create `~/.claude/` on the host if it doesn't exist (like we do for secrets dirs), and always mount it. This way Claude Code can write credentials on first auth without the mount failing.

## Risks / Trade-offs

- [Risk] Users who only have API keys (no Max/Pro) lose the menu-driven key entry. Mitigation: they can set `ANTHROPIC_API_KEY` in their shell profile, or run `claude login` on the host which works for all account types.
- [Risk] Removing `~/.claude/` could delete user settings beyond just credentials. Mitigation: only remove credential-specific files, or document that reset clears all Claude settings. Claude Code recreates defaults on next run.
