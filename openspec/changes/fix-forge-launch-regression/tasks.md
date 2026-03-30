## 1. Fix Claude Code API Key Injection

- [ ] 1.1 In `entrypoint.sh`, replace `exec "$CC_BIN" "$@"` (line 126) with `exec env ANTHROPIC_API_KEY="$_CLAUDE_KEY" "$CC_BIN" "$@"` to re-inject the captured API key at exec time
- [ ] 1.2 Apply same pattern for OpenCode if it needs env vars in the future (currently it does not use API keys, so no change needed)
- [ ] 1.3 Verify: launch a Claude forge container with `ANTHROPIC_API_KEY` set, confirm Claude Code can authenticate

## 2. Fix Silent Install Failures

- [ ] 2.1 Remove `2>/dev/null` from `npm install -g --prefix "$CC_PREFIX" @anthropic-ai/claude-code` (line 76) so errors are visible
- [ ] 2.2 Remove `2>/dev/null` from the OpenSpec install (line 89) for consistency
- [ ] 2.3 Add a post-install verification: run `"$CC_BIN" --version` after install, print result or error
- [ ] 2.4 Add a post-install verification for OpenCode: run `"$OC_BIN" --version` after install
- [ ] 2.5 Improve fallback message: instead of "Claude Code not available. Starting bash.", print the specific failure reason and suggest `tillandsias --bash <project>` for debugging

## 3. Add Update Check (Claude Code)

- [ ] 3.1 Add `update_claude()` function that compares installed version with latest npm version
- [ ] 3.2 Rate-limit the check to once per 24 hours via a timestamp file at `$CACHE/claude/.last-update-check`
- [ ] 3.3 If update available, run `npm install -g --prefix "$CC_PREFIX" @anthropic-ai/claude-code` with visible output
- [ ] 3.4 If update fails, continue with existing version (non-blocking)

## 4. Add Update Check (OpenCode)

- [ ] 4.1 Add `update_opencode()` function that checks GitHub releases API for newer version
- [ ] 4.2 Rate-limit to once per 24 hours via `$CACHE/opencode/.last-update-check`
- [ ] 4.3 If update available, download and replace binary
- [ ] 4.4 If update fails, continue with existing version (non-blocking)

## 5. Image Rebuild and Test

- [ ] 5.1 Rebuild forge image via `scripts/build-image.sh forge --force` to pick up entrypoint changes
- [ ] 5.2 Test: Claude forge launch — verify Claude Code starts with API key access
- [ ] 5.3 Test: OpenCode forge launch — verify OpenCode starts correctly
- [ ] 5.4 Test: Launch with empty cache (first install) — verify install succeeds with visible output
- [ ] 5.5 Test: Launch with corrupt cache (delete binary but keep dir) — verify re-install happens
- [ ] 5.6 Test: Launch with no network — verify graceful fallback
