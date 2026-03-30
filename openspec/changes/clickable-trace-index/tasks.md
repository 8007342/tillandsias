## 1. Script — generate-traces.sh

- [ ] 1.1 Create `scripts/generate-traces.sh` with shebang, `set -euo pipefail`, and `@trace spec:clickable-trace-index`
- [ ] 1.2 Implement scan: grep all `.rs`, `.sh`, `.toml`, `.nix` files for `@trace spec:<name>` patterns, collect file path + line number + spec names
- [ ] 1.3 Implement spec resolution: for each unique spec name, locate `openspec/specs/<name>/spec.md` (active) or `openspec/changes/archive/*/<name>/spec.md` (archived); mark missing specs as `(not found)`
- [ ] 1.4 Implement root `TRACES.md` generation: header, regeneration notice, table with columns Trace / Spec / Source Files; source file links use relative paths with `#L<n>` anchors
- [ ] 1.5 Implement per-spec `TRACES.md` generation: for each spec with at least one trace, write `openspec/specs/<name>/TRACES.md` with back-links; relative paths from the spec dir to source files
- [ ] 1.6 Make script executable (`chmod +x`)

## 2. Build integration

- [ ] 2.1 Add `generate-traces.sh` call to `build.sh` after the version bump line (non-test, non-check builds only)

## 3. Initial generation

- [ ] 3.1 Run `./scripts/generate-traces.sh` to produce initial `TRACES.md` from the 38 existing annotations
- [ ] 3.2 Verify `TRACES.md` renders correctly: table has expected rows, links are relative, anchors are present
- [ ] 3.3 Verify per-spec `TRACES.md` files are created for each active spec that has traces
- [ ] 3.4 Spot-check one archived spec (`tray-icon-lifecycle`) to confirm it links to the archive path

## 4. Verify

- [ ] 4.1 Confirm `TRACES.md` contains all 11 unique spec names found in the codebase
- [ ] 4.2 Confirm per-spec `TRACES.md` files exist for each active spec in the trace index
- [ ] 4.3 Confirm script is idempotent (running twice produces identical output)
- [ ] 4.4 Confirm `./build.sh --check` still passes with the new `build.sh` line
