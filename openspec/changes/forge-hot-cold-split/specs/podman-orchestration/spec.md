## MODIFIED Requirements

### Requirement: Typed TmpfsMount with size_mb cap

`build_podman_args()` SHALL emit `--tmpfs=<path>:size=<N>m,mode=<oct>` for every
`TmpfsMount` in the profile, using the typed `TmpfsMount { path, size_mb, mode }`
struct rather than bare strings. The `if profile.read_only` gate that previously
suppressed tmpfs emission SHALL be removed — tmpfs mounts are emitted regardless
of root-FS mode.

> Delta: `tmpfs_mounts` in `ContainerProfile` changes from `Vec<&'static str>` (bare
> paths, no quota) to `Vec<TmpfsMount>` where each mount carries a `path`, a
> `size_mb` kernel-enforced cap, and an octal `mode`. The `if profile.read_only`
> gate that previously suppressed tmpfs emission is removed — tmpfs mounts are
> emitted regardless of root-FS mode.
`TmpfsMount` in the profile, where:
- `<path>` is the absolute container path
- `<N>` is `TmpfsMount.size_mb` in MiB
- `<oct>` is `TmpfsMount.mode` formatted as a 4-digit octal integer (e.g., `01777`)

The `mode=` field SHALL always be present. The `size=` field SHALL always be present
and SHALL be non-zero.

#### Scenario: TmpfsMount with size_mb cap emits size=<N>m in podman argv

- **WHEN** `build_podman_args()` processes a profile with `TmpfsMount { path: "/tmp", size_mb: 256, mode: 0o1777 }`
- **THEN** the resulting argv contains `--tmpfs=/tmp:size=256m,mode=01777`
- **AND** NOT `--tmpfs=/tmp` (bare path without size cap is forbidden)

#### Scenario: Service profiles (web, git, inference) carry 64 MB tmpfs caps on their existing mounts

- **WHEN** `build_podman_args()` processes the `web` or `git_service` profiles
- **THEN** every existing tmpfs mount is emitted with `size=64m`

---

### Requirement: --memory pairing whenever any tmpfs mount is present

When `tmpfs_mounts` is non-empty, `build_podman_args()` SHALL append both
`--memory=<ceiling>m` and `--memory-swap=<ceiling>m` where the ceiling is
`sum(tmpfs.size_mb) + 256` (256 MB working-set baseline). This ensures zero net
swap allocation from the container.

> Delta: when `tmpfs_mounts` is non-empty, `build_podman_args()` appends
> `--memory=<ceiling>m` and `--memory-swap=<ceiling>m` to cap the container's
> aggregate RAM consumption. The ceiling is `sum(tmpfs.size_mb) + 256` (256 MB
> working-set baseline).

`--memory-swap` SHALL equal `--memory` exactly, ensuring zero net swap allocation.
This is the "no swap escape from the RAM-only guarantee" rule.

#### Scenario: --memory and --memory-swap appended when tmpfs is non-empty

- **WHEN** a profile has one or more tmpfs mounts
- **THEN** the podman argv contains both `--memory=<N>m` and `--memory-swap=<N>m`
  where N = sum of all tmpfs size_mb caps + 256

#### Scenario: Profiles with no tmpfs mounts emit no --memory flag

- **WHEN** a profile has an empty `tmpfs_mounts` list
- **THEN** the podman argv does NOT contain `--memory` or `--memory-swap`
- **AND** host RAM is the only ceiling (existing behaviour preserved)

## Sources of Truth

- `cheatsheets/runtime/forge-hot-cold-split.md` — tmpfs mount table, --memory pairing rationale
- `cheatsheets/build/cargo.md` — Rust struct and arg-builder patterns used in TmpfsMount + build_podman_args
