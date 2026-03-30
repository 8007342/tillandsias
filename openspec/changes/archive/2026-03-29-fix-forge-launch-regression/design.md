## Context

The current `entrypoint.sh` (144 lines) handles Claude Code installation via `install_claude()` at line 70-84. The function runs `npm install -g --prefix "$CC_PREFIX" @anthropic-ai/claude-code 2>/dev/null || true` which suppresses all error output. When this fails (common: npm cache corruption, network timeout, permission issue inside bind-mounted cache), the `if [ -x "$CC_BIN" ]` check at line 77 silently falls through. The entrypoint then reaches the launch block at line 125, finds `$CC_BIN` does not exist, and falls back to `exec bash` with the message "Claude Code not available. Starting bash." The user sees a bare shell with no explanation of what failed.

Additionally, the API key flow is broken. Line 40-41 captures the key (`_CLAUDE_KEY="${ANTHROPIC_API_KEY:-}"`) then scrubs it (`unset ANTHROPIC_API_KEY`). But at line 126, `exec "$CC_BIN" "$@"` runs Claude Code without re-injecting the key. Claude Code starts but cannot authenticate.

**Constraints:**
- Fix must work within the current monolithic entrypoint (modularization is a separate change)
- Fix must not break OpenCode path
- Fix must be backward-compatible with existing cached installs
- Fix must work on both x86_64 and aarch64

## Goals / Non-Goals

**Goals:**
- Claude Code installs reliably and shows diagnostic output on failure
- API key is properly injected at exec time
- Update check runs on each launch (non-blocking for existing installs)
- Clear user-facing error messages when things fail

**Non-Goals:**
- Modularize the entrypoint (separate change: `modular-entrypoints`)
- Change the image build process
- Add retry logic for network failures (user can restart the container)
- Support offline-first installation

## Decisions

### D1: Fix API key injection via exec env

**Choice:** Replace `exec "$CC_BIN" "$@"` with `exec env ANTHROPIC_API_KEY="$_CLAUDE_KEY" "$CC_BIN" "$@"`

**Why:** The `exec env VAR=val command` pattern injects the variable into exactly one process's environment — the agent. The key never appears in the entrypoint's own environment (it was already unset). This is the minimal-exposure pattern: the key exists only in Claude Code's process, not in the shell's exported environment where a rogue child process could read it.

**Alternative considered:** `export ANTHROPIC_API_KEY="$_CLAUDE_KEY"` before exec — this re-exports the key into the shell environment, making it visible to any process spawned between the export and the exec. Less secure.

### D2: Show npm install output on failure

**Choice:** Remove `2>/dev/null` from the npm install command. Redirect stderr to stdout so the user sees what went wrong. Keep `|| true` so the entrypoint continues to the fallback path.

**Why:** Silent failures are the root cause of the debugging difficulty. npm's error output (e.g., "EACCES", "ETARGET", "network timeout") is exactly what the user or developer needs to diagnose the issue.

### D3: Add version check and update on each launch

**Choice:** Before launching the agent, compare the installed version (`claude --version`) with the latest available (`npm view @anthropic-ai/claude-code version`). If a newer version is available, run `npm install -g --prefix` to update. Skip the check if offline (curl/npm fails).

**Why:** Users cache the Claude Code binary in `~/.cache/tillandsias/claude/`. Containers are ephemeral but the cache persists. Without an update check, users run stale versions indefinitely. The check adds ~1-2 seconds on a warm npm cache.

**Rate limit:** Check at most once per 24 hours. Write a timestamp to `$CACHE/claude/.last-update-check`. Skip if the file is newer than 24h.

### D4: Verify binary after install

**Choice:** After install, run `"$CC_BIN" --version` and check exit code. If it fails, print a diagnostic message and fall back to bash with a clear explanation.

**Why:** npm can "succeed" (exit 0) but produce a broken binary (missing deps, wrong architecture, corrupt download). The version check catches this.

### D5: OpenCode gets the same treatment

**Choice:** Apply the same patterns (show errors, verify binary, update check) to `install_opencode()` for consistency.

**Why:** OpenCode's install path is simpler (single binary download) but still has the `2>/dev/null` suppression pattern. Applying the same fixes ensures both agents are equally robust.

## Risks / Trade-offs

**[npm network dependency]** The update check requires network access. If the container has no network (air-gapped), the check must fail gracefully. Mitigation: The update check is wrapped in a timeout and `|| true`.

**[Cache invalidation]** Updating Claude Code in the shared cache while another container is running could cause issues. Mitigation: npm install is atomic at the file level (write to temp, rename). The risk is minimal.

**[Startup latency]** The version check adds 1-2 seconds. Mitigation: Only runs once per 24 hours. Cached check is a stat() on one file.
