## Tasks

- [ ] 1. In `images/default/entrypoint.sh`, after the project directory detection block (line 54) and before the banner (line 56), add an OpenSpec init block:
  - Guard: `[ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ] && [ ! -d "$PROJECT_DIR/openspec" ]`
  - Run: `"$OS_BIN" init --tools opencode` (non-interactive, in the project directory, already cd'd)
  - Print: `"  ✓ OpenSpec initialized"` on success
  - Fail-open: append `|| echo "  ⚠ OpenSpec init skipped"` to prevent set -e abort
- [ ] 2. Verify the embedded entrypoint in `src-tauri/src/embedded.rs` references `images/default/entrypoint.sh` via `include_str!` — confirm the change will be picked up on next build
- [ ] 3. Test: rebuild forge image (`./scripts/build-image.sh forge --force`) and launch a new environment to verify OpenSpec is initialized automatically
