# Forge Build Cache and Attestation Reachability Fixes (2026-08-24)

## Context & Observations

During the 2026-08-24 forge meta-orchestration cycle while implementing slice B of `795-hzpg` (podman-sync-wait-bounded-busy-polls-two-detached-threads), three infrastructure roughness issues were identified and resolved in the same cycle:

1. **Archive Answerability Build Target on Small `/tmp` tmpfs**:
   - `scripts/check-archive-answerability.sh` previously defaulted `WORK` to `${TMPDIR:-/tmp}/tillandsias-archive-answerability`.
   - In container/forge environments where `/tmp` is mounted as a 256MB tmpfs, `cargo build` in `check-archive-answerability.sh` ran out of space (`No space left on device`, os error 28).
   - Fixed by placing `WORK` under `${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/tillandsias-archive-answerability`, using the large persistent overlay partition.

2. **Capability Row Probe Host Kind Isolation in Forge**:
   - `scripts/agent-identity.sh` was updated so `TILLANDSIAS_HOST_KIND` takes precedence before checking the `.forge-startup-context.md` file marker, allowing test harnesses to explicitly test non-forge host kinds even when running inside a forge container.
   - `scripts/test-capability-row-check.sh`'s `run_sut` was updated to default `TILLANDSIAS_HOST_KIND=linux` for cases 1-6.

3. **MO-FULL Ledger Multi-Branch Reachability in Shallow/Partial Clones**:
   - `scripts/check-mo-full-attestations.sh` previously only inspected `refs/heads/$branch` when checking commit reachability for own-host attestation entries.
   - When a host (such as forge) has historical attestations across multiple branches (`linux-next`, `windows-next`), only the currently checked out local branches exist under `refs/heads/`, while other remote branches exist under `refs/remotes/origin/$branch`.
   - Fixed by checking `refs/heads/$branch` first and falling back to `refs/remotes/origin/$branch` if present.

