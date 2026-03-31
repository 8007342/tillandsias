## 1. Fix OpenCode config format

- [ ] 1.1 Replace `images/default/opencode.json` — use `"permission"` (singular) with valid tool-level format, add `"autoupdate": false`, add `"$schema"`
- [ ] 1.2 Verify Containerfile copies to correct path (`/home/forge/.config/opencode/config.json`)

## 2. Fix AppImage relative path resolution

- [ ] 2.1 In `runner.rs`, resolve relative paths against `$OWD` when set, before calling `canonicalize()`
- [ ] 2.2 Add `@trace spec:cli-mode` comment at the resolution point

## 3. Verify

- [ ] 3.1 `./build.sh --test` — all tests pass
- [ ] 3.2 `./build.sh --check` — type-check clean
- [ ] 3.3 Manual: `tillandsias .` resolves to user's CWD (verify with `--debug`)
