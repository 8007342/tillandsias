# forge-hot-cold-split Specification

## Status

status: active

## Purpose
TBD - created by archiving change forge-hot-cold-split. Update Purpose after archive.
## Requirements
### Requirement: HOT tier — RAM-backed tmpfs for finely curated paths

Every forge profile (OpenCode, Claude, OpenCode-Web, maintenance terminal) MUST
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
- **THEN** `findmnt -t tmpfs` inside the container MUST list `/opt/cheatsheets`,
  `/home/forge/src`, `/tmp`, and `/run/user/1000`
- **AND** each mount's reported size MUST match the cap in the table above (within
  page-alignment rounding)

#### Scenario: Cheatsheets populated from image-baked staging directory at entrypoint

- **WHEN** `populate_hot_paths()` runs inside the forge entrypoint (before any
  agent-visible work)
- **THEN** `cp -a /opt/cheatsheets-image/. /opt/cheatsheets/` MUST succeed
- **AND** `ls /opt/cheatsheets/INDEX.md` MUST return the same file that was baked
  into `/opt/cheatsheets-image/` at image-build time
- **AND** the copy MUST be idempotent (re-running `populate_hot_paths()` is safe)

---

### Requirement: Per-mount size caps

Every tmpfs mount MUST carry a kernel-enforced size cap expressed as
`--tmpfs=<path>:size=<N>m,mode=<oct>` in the podman arguments. The cap is NOT
advisory: writes that would exceed it MUST fail with ENOSPC.

#### Scenario: /opt/cheatsheets capped at 8 MB

- **WHEN** the forge container starts
- **THEN** `df --output=size /opt/cheatsheets` MUST report ≈ 8192 blocks (8 MB)
- **AND** writing more than 8 MB of data under `/opt/cheatsheets/` MUST fail with ENOSPC

#### Scenario: /home/forge/src sized per-launch from compute_hot_budget

- **WHEN** a forge launch context is built for project `foo`
- **THEN** `compute_hot_budget("foo", <cache_dir>)` MUST be called
- **AND** the returned budget (in MB) MUST be embedded as the size cap of the
  `/home/forge/src` tmpfs mount
- **AND** `df --output=size /home/forge/src` inside the container MUST match the
  per-launch budget (within page rounding)

#### Scenario: /tmp capped at 256 MB

- **WHEN** the forge container starts
- **THEN** `df --output=size /tmp` MUST report ≈ 262144 blocks (256 MB)
- **AND** `dd if=/dev/zero of=/tmp/x bs=1M count=512` MUST fail at approximately
  256 MB with an ENOSPC error

#### Scenario: /run/user/1000 capped at 64 MB

- **WHEN** the forge container starts
- **THEN** `df --output=size /run/user/1000` MUST report ≈ 65536 blocks (64 MB)

---

### Requirement: --memory ceiling pairs with tmpfs caps

When ANY tmpfs mount is present in the profile, the podman invocation MUST also
pass `--memory=<ceiling>m` and `--memory-swap=<ceiling>m` (no swap escape).

The ceiling is: `sum(all tmpfs size_mb) + 256` (256 MB working-set baseline).

- `--memory-swap` MUST equal `--memory` exactly (zero additional swap).

#### Scenario: --memory and --memory-swap match (no swap escape)

- **WHEN** `build_podman_args()` produces a forge container's podman argv
- **THEN** both `--memory=<N>m` and `--memory-swap=<N>m` MUST appear in the argv
- **AND** both values MUST be equal (no net swap allocation)

#### Scenario: --memory = sum(tmpfs caps) + 256 MB working-set baseline

- **WHEN** a forge profile carries four tmpfs mounts totalling
  `8 + budget + 256 + 64` MB
- **THEN** `--memory` MUST be `8 + budget + 256 + 64 + 256` MB
- **AND** `--memory-swap` MUST equal the same value

---

### Requirement: Pre-flight RAM check refuses launch on insufficient host RAM

The host available RAM MUST be measured before every forge launch via platform-native APIs (Linux: `/proc/meminfo`; macOS: `vm_stat`; Windows: `GlobalMemoryStatusEx`). If `mem_available_mb < required_mb × 1.25` (1.25× headroom factor), the launch MUST be refused immediately — no podman invocation occurs.

#### Scenario: Refusal emits friendly tray notification + structured accountability log

- **WHEN** the pre-flight check returns `PreflightError::InsufficientRam`
- **THEN** a desktop notification MUST be sent with a human-readable message explaining:
  - how much RAM is required
  - how much is available
  - how the user can resolve it (prune mirror refs or raise `hot_path_max_mb`)
- **AND** a structured log event MUST be emitted with:
  - `accountability = true`
  - `category = "forge-launch"`
  - `spec = "forge-hot-cold-split"`
  - `host_mem_available_mb = <measured value>`
  - `budget_mb = <ctx.hot_path_budget_mb>`
  - `decision = "refuse"`
- **AND** podman MUST NOT be invoked

#### Scenario: Refusal does NOT invoke podman

- **WHEN** pre-flight returns `InsufficientRam`
- **THEN** no `podman run` command MUST be executed
- **AND** the in-memory container state MUST be reverted (running list de-registered)

#### Scenario: 1.25× headroom factor between MemAvailable and required

- **WHEN** `check_host_ram(required_mb)` is called
- **THEN** the threshold MUST be `ceil(required_mb × 1.25)` MB
- **AND** if `mem_available_mb >= threshold`, the result MUST be `Ok(HostRamCheck)`
- **AND** if `mem_available_mb < threshold`, the result MUST be `Err(InsufficientRam)`

---

### Requirement: Per-launch project source budget

The `/home/forge/src` tmpfs size MUST be computed per-launch from the project's
git mirror pack size.

`compute_hot_budget(project_name, cache_dir)`:
1. Runs `git -C <mirror> count-objects -v -H | grep size-pack`
2. Parses the reported pack size in KB
3. Multiplies by `forge.hot_path_inflation` (default 4, configurable in
   `~/.config/tillandsias/config.toml`)
4. Clamps to `[256, forge.hot_path_max_mb]` (default max: 4096 MB)

#### Scenario: Budget = git mirror's size-pack × forge.hot_path_inflation, clamped [256, forge.hot_path_max_mb]

- **WHEN** the mirror's pack size is 200 MB and `hot_path_inflation` is 4
- **THEN** the computed budget MUST be 800 MB (200 × 4), within [256, 4096]

#### Scenario: Empty mirror returns floor (256 MB)

- **WHEN** the git mirror is empty or `count-objects` returns 0
- **THEN** `compute_hot_budget` MUST return 256 MB (the floor)

#### Scenario: Budget exceeds max_mb → clamped at ceiling

- **WHEN** the mirror's pack size × inflation exceeds `hot_path_max_mb`
- **THEN** `compute_hot_budget` MUST return `hot_path_max_mb` (default 4096 MB)

---

### Requirement: Agent transparency

The HOT tier MUST change only the BACKING STORE of agent-visible paths — the paths themselves MUST remain byte-identical. Agents experience zero behavioral difference and require no code or env-var changes.

#### Scenario: Agents see /home/forge/src/<project>/ and /opt/cheatsheets/ as the SAME paths (zero env-var change)

- **WHEN** an agent reads files under `/home/forge/src/<project>/` or
  `/opt/cheatsheets/` before and after the hot/cold split lands
- **THEN** the paths MUST be byte-identical to before — no code or cheatsheet
  reference needs updating
- **AND** no new env var MUST be required to locate source or cheatsheets

#### Scenario: TILLANDSIAS_CHEATSHEETS env var unchanged

- **WHEN** an agent runs `echo $TILLANDSIAS_CHEATSHEETS` inside a forge container
- **THEN** the output MUST be `/opt/cheatsheets` — unchanged from before this split

---

### Requirement: Tmpfs-overlay lane for per-project ephemeral cache

A third storage pattern MUST be admitted alongside HOT (kernel tmpfs with hard cap, ENOSPC on overflow) and COLD (disk, no spec-level cap): the **tmpfs-overlay lane**. The tmpfs-overlay lane is a tmpfs view rooted on top of a COLD per-project cache directory, with LRU eviction across the tmpfs/disk boundary as a single per-project pool. The tmpfs-overlay lane is NOT a fifth HOT root; the four HOT roots (`/opt/cheatsheets`, `/home/forge/src`, `/tmp`, `/run/user/1000`) MUST remain unchanged. The tmpfs-overlay lane is scoped to `~/.cache/tillandsias/cheatsheets-pulled/` only; other paths require a dedicated spec change to opt in.

The tmpfs-overlay lane MUST be sized at tray startup based on host `MemTotal`:

| `MemTotal` (from `/proc/meminfo`) | Tmpfs cap | User override |
|---|---|---|
| `< 8 GiB` | 64 MB | `forge.pull_cache_ram_mb` in `~/.config/tillandsias/config.toml` |
| `8 GiB ≤ MemTotal < 32 GiB` | 128 MB | same |
| `≥ 32 GiB` | 1024 MB | same |

The resolved cap MUST be passed into the forge container via the env var `TILLANDSIAS_PULL_CACHE_RAM_MB` so the in-forge cache implementation knows the budget without re-reading `/proc/meminfo`.

#### Scenario: Tmpfs-overlay cap auto-detected at tray startup

- **WHEN** the tray starts on a host with `MemTotal = 16 GiB`
- **THEN** the resolved tmpfs cap MUST be 128 MB
- **AND** every forge container launched after this point MUST receive `TILLANDSIAS_PULL_CACHE_RAM_MB=128` in its environment
- **AND** if the user's config sets `forge.pull_cache_ram_mb = 256`, the override MUST win and the env var MUST be `256`

#### Scenario: Tmpfs-overlay write succeeds past cap by demoting LRU to disk

- **WHEN** the in-forge agent writes content to `~/.cache/tillandsias/cheatsheets-pulled/<project>/<host>/<path>` that would exceed the tmpfs cap
- **THEN** the cache implementation MUST demote the least-recently-accessed file in the SAME PROJECT's subtree from tmpfs to the disk-backed portion of the same per-project pull cache
- **AND** the new write MUST succeed without ENOSPC
- **AND** the demoted file MUST remain readable from the same path (tmpfs/disk transition is transparent to readers)

#### Scenario: Tmpfs-overlay eviction NEVER crosses project boundaries

- **WHEN** project A's tmpfs-overlay portion is full and project A is writing
- **THEN** eviction MUST only consider files in project A's subtree
- **AND** project B's bytes MUST NOT be evicted, demoted, or even read
- **AND** this invariant MUST hold even if project B's tmpfs portion is empty (idle space is not borrowable across projects per `forge-cache-dual`)

#### Scenario: Tmpfs-overlay is NOT a HOT root

- **WHEN** the spec test that enumerates HOT roots runs (the existing scenario from `Requirement: HOT tier — RAM-backed tmpfs for finely curated paths`)
- **THEN** the four HOT root paths MUST be exactly `/opt/cheatsheets`, `/home/forge/src`, `/tmp`, `/run/user/1000`
- **AND** `~/.cache/tillandsias/cheatsheets-pulled/` MUST NOT appear in that enumeration
- **AND** the "Maybe a hot path" HARD NO rule MUST remain unweakened


## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/architecture/event-driven-basics.md` — Event Driven Basics reference and patterns

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Hot/cold split is ephemeral; hot paths are tmpfs; cold paths are read-only
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:forge-hot-cold-split" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
