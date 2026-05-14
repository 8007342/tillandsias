<!-- @trace spec:cross-platform -->
# Spec: Cross-Platform Windows Support (Delta)

## Status

deprecated

## Tombstone

`cross-platform` was an umbrella for Windows-specific deltas. Its live obligations now
live in narrower specs:

- `windows-wsl-runtime`
- `windows-native-dev-build`
- `windows-process-creation`
- `no-terminal-flicker`
- `windows-sandbox`
- `fix-windows-extended-path`
- `fix-windows-image-routing`
- `fix-podman-machine-host-aliases`

## Requirements

### OBSOLETED REQUIREMENTS

The old Windows delta requirements were distilled into the narrower specs listed
above and are intentionally no longer owned here.

## Sources of Truth

- `cheatsheets/runtime/wsl2-isolation-boundary.md` — WSL2 isolation boundary reference and patterns
- `cheatsheets/runtime/windows-event-viewer.md` — Windows Event Viewer reference and patterns

## Litmus Tests

None. This spec is deprecated and kept only for traceability of the old umbrella.

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:cross-platform" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
