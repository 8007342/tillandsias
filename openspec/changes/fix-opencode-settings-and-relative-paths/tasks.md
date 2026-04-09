## 1. Fix OpenCode config format

- [x] 1.1 Replace `images/default/opencode.json` — use `"permission"` (singular) with valid tool-level format, add `"autoupdate": false`, add `"$schema"`
- [x] 1.2 Verify Containerfile copies to correct path (`/home/forge/.config/opencode/config.json`)

## 2. Fix AppImage relative path resolution

- [x] 2.1 In `runner.rs`, resolve relative paths against `$OWD` when set, before calling `canonicalize()`
- [x] 2.2 Add `@trace spec:cli-mode` comment at the resolution point

## 3. Verify

- [x] 3.1 `./build.sh --test` — all tests pass
- [x] 3.2 `./build.sh --check` — type-check clean
- [x] 3.3 Manual: `tillandsias .` resolves to user's CWD (verify with `--debug`)
