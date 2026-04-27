## MODIFIED Requirements

### Requirement: Forge containers see exactly four path categories

The "Ephemeral" category SHALL carry kernel-enforced size caps on `/tmp` (256 MB)
and `/run/user/1000` (64 MB). These paths were previously unbounded (defaulting
to 50% of host RAM under `tmpfs(5)` semantics); after this change they are
bounded and fail with ENOSPC on overflow.

> Delta: the "Ephemeral" row in the path-category table gains explicit kernel-enforced size
> caps on `/tmp` and `/run/user/1000`. These paths were previously unbounded (defaulting
> to 50% of host RAM under `tmpfs(5)` semantics). After this change they are bounded.

| Ephemeral path | Mount type | Size cap |
|---|---|---|
| `/tmp` | tmpfs | **256 MB** (0o1777) |
| `/run/user/1000` | tmpfs | **64 MB** (0o0700) |
| All other unmounted home dirs / overlay | container's own writable layer | (none) |

The `/tmp` and `/run/user/1000` caps are kernel-enforced via `--tmpfs=<path>:size=<N>m,mode=<oct>`.
Writes beyond the cap fail with ENOSPC inside the container.

#### Scenario: /tmp is capped at 256 MB

- **WHEN** a forge container starts
- **THEN** `df --output=size /tmp` reports ≈ 256 MB
- **AND** writing more than 256 MB to `/tmp/` fails with ENOSPC — not silently spilling to disk

#### Scenario: /run/user/1000 is capped at 64 MB

- **WHEN** a forge container starts
- **THEN** `df --output=size /run/user/1000` reports ≈ 64 MB
- **AND** the cap prevents runaway socket or log files from consuming unbounded RAM

#### Scenario: Unbounded overlay still covers non-tmpfs ephemeral paths

- **WHEN** an agent writes to a path that is neither `/tmp` nor `/run/user/1000` nor a
  bind-mounted cache (e.g., `/home/forge/.bashrc`)
- **THEN** the write lands in the container's overlayfs upper-dir on the host storage
  driver — subject to host disk quota, not RAM quota

## Sources of Truth

- `cheatsheets/runtime/forge-hot-cold-split.md` — HOT/COLD classification and size-cap table
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — full path taxonomy with backing-store column
