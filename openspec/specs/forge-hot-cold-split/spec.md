# forge-hot-cold-split Specification

## Purpose
TBD - created by archiving change forge-hot-cold-split. Update Purpose after archive.
## Requirements
### Requirement: HOT tier — RAM-backed tmpfs for finely curated paths

Every forge profile (OpenCode, Claude, OpenCode-Web, maintenance terminal) SHALL
mount the following paths as kernel tmpfs at container start time:

| Path | Size cap | mode |
|------|----------|------|
| `/opt/cheatsheets` | 8 MB | 0755 |
| `/home/forge/src` | `compute_hot_budget()` MB (per-launch) | 0755 |
| `/tmp` | 256 MB | 01777 |
| `/run/user/1000` | 64 MB | 0700 |

Only these four path roots are HOT. "Maybe a hot path" is a HARD NO. All other
paths (build artefacts, `/nix/store`, caches, logs) remain COLD.

#### Scenario: All four hot paths are mounted as tmpfs on every forge launch

- **WHEN** a forge container starts (any entrypoint: OpenCode, Claude, web-mode, terminal)
- **THEN** `findmnt -t tmpfs` inside the container lists `/opt/cheatsheets`,
  `/home/forge/src`, `/tmp`, and `/run/user/1000`
- **AND** each mount's reported size matches the cap in the table above (within
  page-alignment rounding)

#### Scenario: Cheatsheets populated from image-baked staging directory at entrypoint

- **WHEN** `populate_hot_paths()` runs inside the forge entrypoint (before any
  agent-visible work)
- **THEN** `cp -a /opt/cheatsheets-image/. /opt/cheatsheets/` succeeds
- **AND** `ls /opt/cheatsheets/INDEX.md` returns the same file that was baked
  into `/opt/cheatsheets-image/` at image-build time
- **AND** the copy is idempotent (re-running `populate_hot_paths()` is safe)

---

### Requirement: Per-mount size caps

Every tmpfs mount SHALL carry a kernel-enforced size cap expressed as
`--tmpfs=<path>:size=<N>m,mode=<oct>` in the podman arguments. The cap is NOT
advisory: writes that would exceed it SHALL fail with ENOSPC.

#### Scenario: /opt/cheatsheets capped at 8 MB

- **WHEN** the forge container starts
- **THEN** `df --output=size /opt/cheatsheets` reports ≈ 8192 blocks (8 MB)
- **AND** writing more than 8 MB of data under `/opt/cheatsheets/` fails with ENOSPC

#### Scenario: /home/forge/src sized per-launch from compute_hot_budget

- **WHEN** a forge launch context is built for project `foo`
- **THEN** `compute_hot_budget("foo", <cache_dir>)` is called
- **AND** the returned budget (in MB) is embedded as the size cap of the
  `/home/forge/src` tmpfs mount
- **AND** `df --output=size /home/forge/src` inside the container matches the
  per-launch budget (within page rounding)

#### Scenario: /tmp capped at 256 MB

- **WHEN** the forge container starts
- **THEN** `df --output=size /tmp` reports ≈ 262144 blocks (256 MB)
- **AND** `dd if=/dev/zero of=/tmp/x bs=1M count=512` fails at approximately
  256 MB with an ENOSPC error

#### Scenario: /run/user/1000 capped at 64 MB

- **WHEN** the forge container starts
- **THEN** `df --output=size /run/user/1000` reports ≈ 65536 blocks (64 MB)

---

### Requirement: --memory ceiling pairs with tmpfs caps

When ANY tmpfs mount is present in the profile, the podman invocation SHALL also
pass `--memory=<ceiling>m` and `--memory-swap=<ceiling>m` (no swap escape).

The ceiling is: `sum(all tmpfs size_mb) + 256` (256 MB working-set baseline).

- `--memory-swap` equals `--memory` exactly (zero additional swap).

#### Scenario: --memory and --memory-swap match (no swap escape)

- **WHEN** `build_podman_args()` produces a forge container's podman argv
- **THEN** both `--memory=<N>m` and `--memory-swap=<N>m` appear in the argv
- **AND** both values are equal (no net swap allocation)

#### Scenario: --memory = sum(tmpfs caps) + 256 MB working-set baseline

- **WHEN** a forge profile carries four tmpfs mounts totalling
  `8 + budget + 256 + 64` MB
- **THEN** `--memory` is `8 + budget + 256 + 64 + 256` MB
- **AND** `--memory-swap` equals the same value

---

### Requirement: Pre-flight RAM check refuses launch on insufficient host RAM

The host available RAM SHALL be measured before every forge launch via platform-native APIs (Linux: `/proc/meminfo`; macOS: `vm_stat`; Windows: `GlobalMemoryStatusEx`). If `mem_available_mb < required_mb × 1.25` (1.25× headroom factor), the launch SHALL be refused immediately — no podman invocation occurs.

#### Scenario: Refusal emits friendly tray notification + structured accountability log

- **WHEN** the pre-flight check returns `PreflightError::InsufficientRam`
- **THEN** a desktop notification is sent with a human-readable message explaining:
  - how much RAM is required
  - how much is available
  - how the user can resolve it (prune mirror refs or raise `hot_path_max_mb`)
- **AND** a structured log event is emitted with:
  - `accountability = true`
  - `category = "forge-launch"`
  - `spec = "forge-hot-cold-split"`
  - `host_mem_available_mb = <measured value>`
  - `budget_mb = <ctx.hot_path_budget_mb>`
  - `decision = "refuse"`
- **AND** podman is NOT invoked

#### Scenario: Refusal does NOT invoke podman

- **WHEN** pre-flight returns `InsufficientRam`
- **THEN** no `podman run` command is executed
- **AND** the in-memory container state is reverted (running list de-registered)

#### Scenario: 1.25× headroom factor between MemAvailable and required

- **WHEN** `check_host_ram(required_mb)` is called
- **THEN** the threshold is `ceil(required_mb × 1.25)` MB
- **AND** if `mem_available_mb >= threshold`, the result is `Ok(HostRamCheck)`
- **AND** if `mem_available_mb < threshold`, the result is `Err(InsufficientRam)`

---

### Requirement: Per-launch project source budget

The `/home/forge/src` tmpfs size SHALL be computed per-launch from the project's
git mirror pack size.

`compute_hot_budget(project_name, cache_dir)`:
1. Runs `git -C <mirror> count-objects -v -H | grep size-pack`
2. Parses the reported pack size in KB
3. Multiplies by `forge.hot_path_inflation` (default 4, configurable in
   `~/.config/tillandsias/config.toml`)
4. Clamps to `[256, forge.hot_path_max_mb]` (default max: 4096 MB)

#### Scenario: Budget = git mirror's size-pack × forge.hot_path_inflation, clamped [256, forge.hot_path_max_mb]

- **WHEN** the mirror's pack size is 200 MB and `hot_path_inflation` is 4
- **THEN** the computed budget is 800 MB (200 × 4), within [256, 4096]

#### Scenario: Empty mirror returns floor (256 MB)

- **WHEN** the git mirror is empty or `count-objects` returns 0
- **THEN** `compute_hot_budget` returns 256 MB (the floor)

#### Scenario: Budget exceeds max_mb → clamped at ceiling

- **WHEN** the mirror's pack size × inflation exceeds `hot_path_max_mb`
- **THEN** `compute_hot_budget` returns `hot_path_max_mb` (default 4096 MB)

---

### Requirement: Agent transparency

The HOT tier SHALL change only the BACKING STORE of agent-visible paths — the paths themselves SHALL remain byte-identical. Agents experience zero behavioral difference and require no code or env-var changes.

#### Scenario: Agents see /home/forge/src/<project>/ and /opt/cheatsheets/ as the SAME paths (zero env-var change)

- **WHEN** an agent reads files under `/home/forge/src/<project>/` or
  `/opt/cheatsheets/` before and after the hot/cold split lands
- **THEN** the paths are byte-identical to before — no code or cheatsheet
  reference needs updating
- **AND** no new env var is required to locate source or cheatsheets

#### Scenario: TILLANDSIAS_CHEATSHEETS env var unchanged

- **WHEN** an agent runs `echo $TILLANDSIAS_CHEATSHEETS` inside a forge container
- **THEN** the output is `/opt/cheatsheets` — unchanged from before this split

---

