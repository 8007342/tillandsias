<!-- @tombstone superseded:wsl-runtime+enclave-network+fix-windows-image-routing -->
# fix-podman-machine-host-aliases Specification (Tombstone)

## Status

deprecated

## Tombstone

This spec captured an earlier podman-machine alias-routing investigation. The
live platform behavior is now distributed across the Windows/WSL runtime and
enclave-network specs, with host-alias handling implemented directly in the
launcher code where needed.

The old contract mixed host alias rewrite policy, environment variable rewrite
policy, and platform-specific Podman-machine behavior into one active bucket.
That bucket is now retired.

## Replacement References

- `openspec/specs/wsl-runtime/spec.md`
- `openspec/specs/enclave-network/spec.md`
- `openspec/specs/fix-windows-image-routing/spec.md`

## Sources of Truth

- `cheatsheets/runtime/wsl-runtime.md` — WSL runtime and machine networking
- `cheatsheets/runtime/networking.md` — enclave alias and service discovery patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:fix-podman-machine-host-aliases" crates scripts images methodology --include="*.rs" --include="*.sh"
```
