## 1. Entrypoint Init Wrapper

- [x] 1.1 Cache OpenCode: download to $CACHE/opencode/ if missing, add to PATH
- [x] 1.2 Cache OpenSpec: `npm install --prefix $CACHE/openspec @anthropic-ai/openspec` if missing, add bin to PATH
- [x] 1.3 Both cached in mounted volume, persisted across runs
- [x] 1.4 Entrypoint is idempotent: second run skips all installs

## 2. Mount Path Fix

- [x] 2.1 handlers.rs: mount at `/home/forge/src/<project-name>` instead of `/home/forge/src`
- [x] 2.2 runner.rs: same mount path fix
- [x] 2.3 Entrypoint: cd into the project subdir under src/

## 3. Build and Test

- [ ] 3.1 Test: opencode shows src/lakanoa:main in status bar
- [ ] 3.2 Test second run is instant (no downloads)
