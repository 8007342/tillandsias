## ADDED Requirements

### Requirement: Disk preflight before creating a worktree

Before creating a git worktree, Tillandsias tooling and skills SHALL read the
free space of the target filesystem and list existing worktrees. Below the
threshold (host: max(2 GiB, 15 %); forge L0: 25 % of the tmpfs) it SHALL evict
finished worktrees, oldest first, and refuse with
`refused:disk-low:<path>:<free>` when the threshold cannot be reached.

#### Scenario: low space evicts a pushed worktree

- **GIVEN** free space below the threshold and a clean worktree whose HEAD is contained in a remote ref
- **WHEN** a new worktree is requested
- **THEN** the pushed worktree is removed and the new one is created

#### Scenario: unpushed work is never evicted

- **GIVEN** a worktree with a commit not contained in any remote ref, or with dirty files
- **WHEN** eviction runs
- **THEN** that worktree is kept
- **AND** if the threshold is still unmet the request is refused with the named verdict

### Requirement: Disk-aware skills and startup context

The skills that create worktrees, run builds or gates (listed in design D5)
SHALL invoke the disk preflight, and the forge startup context SHALL report
L0 size/used/threshold, L1 and L2 free space, swap state, host free percent
and the count of evictable worktrees.

#### Scenario: startup context

- **WHEN** a forge agent session starts
- **THEN** the startup context contains a disk line with each of those values
