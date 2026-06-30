# Forge Permission Files — YOLO Mode Audit

trace: plan.yaml (future_intentions item 3),
       plan/steps/58-future-intentions-drain.md

Status: done (already implemented, no code changes needed)
Owner host: linux
Capability tags: [forge, opencode, codex, claude, permissions]

## Objective

Ensure opencode and codex/claude permission files are highly permissive
by default ("near full YOLO mode") for the forge safe environment.

## Audit Findings

### Opencode

- `images/default/config-overlay/opencode/config.json` line 5: `"permission": "allow"`
  — the highest permissiveness level, auto-approves all tool calls.
- `images/default/entrypoint-forge-opencode.sh` lines 156,162: both entrypoint
  paths use `opencode run --dangerously-skip-permissions`, bypassing the
  permission gate at CLI level.
- `images/nanoclawv2/entrypoint.sh` line 15: also uses `--dangerously-skip-permissions`.
- `repeat` script line 270: `opencode run --dangerously-skip-permissions "$PROMPT"`.
- **Result**: fully permissive.

### Codex

- `repeat` script line 262: `codex exec --dangerously-bypass-approvals-and-sandbox`
  — Codex's equivalent of YOLO mode.
- **Result**: fully permissive.

### Claude

- `repeat` script line 266: `claude --dangerously-skip-permissions`.
- No separate `.claude/` directory or claude_settings.json needed — the CLI flag
  is sufficient for non-interactive forge operation.
- **Result**: fully permissive.

### Gemini

- `repeat` script line 274: `gemini --yolo`.
- **Result**: fully permissive.

### Antigravity

- `repeat` script line 279: `agy --dangerously-skip-permissions`.
- **Result**: fully permissive.

## Conclusion

All four agent runtimes (opencode, codex, claude, gemini) and agy already
operate in fully permissive mode inside the forge. The `"permission": "allow"`
config plus `--dangerously-skip-permissions` / equivalent flags on every
entrypoint and via the `repeat` wrapper achieve "near full YOLO mode" for the
forge safe environment. No code or config changes needed.

## Acceptance Evidence

- `grep 'permission.*allow' images/default/config-overlay/opencode/config.json`
  → confirms `"permission": "allow"`.
- `grep 'dangerously-skip-permissions' images/default/entrypoint-forge-opencode.sh`
  → confirms 2 uses.
- `grep -E 'dangerously-(skip-permissions|bypass-approvals)|yolo' repeat`
  → confirms permissive flags for all agents.
