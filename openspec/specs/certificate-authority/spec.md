<!-- @tombstone superseded:reverse-proxy-internal+podman-secrets-integration+secrets-management -->
<!-- @trace spec:reverse-proxy-internal, spec:podman-secrets-integration -->
# certificate-authority Specification

## Status

obsolete

## Purpose

Historical umbrella for the ephemeral CA lifecycle. The live requirements are
now owned by `reverse-proxy-internal`, `podman-secrets-integration`, and
`secrets-management`.

## Superseded By

- `openspec/specs/reverse-proxy-internal/spec.md`
- `openspec/specs/podman-secrets-integration/spec.md`
- `openspec/specs/secrets-management/spec.md`

## Notes

- This tombstone keeps older CA references readable for archive consumers.
- The current code path still generates ephemeral CA material, but its owning
  contracts now live in the more specific specs above.
