<!-- @tombstone superseded:wsl-runtime+fix-windows-image-routing+windows-native-dev-build -->
# fix-windows-extended-path Specification (Tombstone)

## Status

deprecated

## Tombstone

This spec captured an earlier Windows path-canonicalization fix for the legacy
`src-tauri` layout. That layout no longer exists in this repository, and the
specific `simplify_path` contract has been folded into the wider Windows/WSL
runtime and build-path handling work.

The old contract remains as history only. There is no backwards-compatibility
commitment.

## Replacement References

- `openspec/specs/wsl-runtime/spec.md`
- `openspec/specs/fix-windows-image-routing/spec.md`
- `openspec/specs/windows-native-dev-build/spec.md`

## Sources of Truth

- `cheatsheets/runtime/windows-paths.md` — Windows path forms and canonicalization
- `cheatsheets/build/git-operations.md` — git clone semantics and path handling

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:fix-windows-extended-path" crates scripts images methodology --include="*.rs" --include="*.sh"
```
