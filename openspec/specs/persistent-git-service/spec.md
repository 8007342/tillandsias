<!-- @tombstone superseded:git-mirror-service -->
<!-- @trace spec:persistent-git-service -->
# persistent-git-service Specification (Tombstone)

## Status

obsolete

## Deprecation Notice

This per-project git-service lifetime contract has been retired. The live
lifecycle is now described by `git-mirror-service`, which starts the git
service on first attach for a project and stops it when the project's last
forge exits.

There is no backwards-compatibility commitment.

## Historical Context

The retired contract kept `tillandsias-git-<project>` alive across tray-session
reattaches to avoid repeated startup cost. That behavior is no longer the
canonical contract.

## Replacement References

- `openspec/specs/git-mirror-service/spec.md`
