<!-- @tombstone superseded:podman-secrets-integration -->
# secret-rotation Specification

## Status

obsolete

Reconciled 2026-09-26 (1397-eppt): both sides already called this spec dead; the registry carries the lawful tombstone trail (superseded:podman-secrets-integration), so its word, obsolete, is the one both now use.

## Purpose

This spec used to describe tmpfs token files and `GIT_ASKPASS` delivery. That
model has been superseded by `podman-secrets-integration`, which delivers the
GitHub token as a podman secret mounted at `/run/secrets/tillandsias-github-token`
inside the git service container.

## Replacement

- `openspec/specs/podman-secrets-integration/spec.md`
- `openspec/specs/git-mirror-service/spec.md`
- `openspec/specs/native-secrets-store/spec.md`

## Notes

- Legacy trace annotations may still mention `spec:secret-rotation`; they refer
  to historical behavior and should be migrated to `spec:podman-secrets-integration`.
- No active code path should require `GIT_ASKPASS` or bind-mounted GitHub token
  files.
