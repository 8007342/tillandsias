## Decisions

### D1: Init placement — after cd, before OpenCode launch

`openspec init` runs in `entrypoint.sh` between finding the project directory (line 54) and launching OpenCode (line 65). This ensures the `openspec/` directory exists when OpenCode starts.

### D2: Idempotent — skip if already initialized

Guard with `[ ! -d "$PROJECT_DIR/openspec" ]`. If the project already has an `openspec/` directory (from a prior run or manual init), skip. This makes repeated container launches fast.

### D3: Fail-open — don't block on init failure

If `openspec init` fails (network, permissions, etc.), log a warning and continue. The user can still use OpenCode and initialize OpenSpec manually. Use `|| true` to prevent `set -e` from aborting the entrypoint.

### D4: Only init when OpenSpec binary is available

Guard with `[ -x "$OS_BIN" ]` before attempting init. If OpenSpec installation was deferred (npm failure), skip the init step silently.
