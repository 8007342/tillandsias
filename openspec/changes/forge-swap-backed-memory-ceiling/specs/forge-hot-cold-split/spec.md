## MODIFIED Requirements

### Requirement: --memory ceiling pairs with tmpfs caps
<!-- req-id: 0d24437b -->

When ANY tmpfs mount is present in the profile, the podman invocation MUST
pass a memory BUDGET, not a ceiling: `--memory=<max>m` (cgroup `memory.max`),
`--memory-swap=<max + swap_allowance>m` (cgroup `memory.swap.max` =
`swap_allowance`), `--memory-reservation=<low>m` (cgroup `memory.low`) and
`--cgroup-conf=memory.high=<bytes>` (cgroup `memory.high`).

- `swap_allowance` MUST be at least `sum(all HOT tmpfs size_mb) + 1024`, so a
  tmpfs that fills spills to swap or fails with ENOSPC and never reaches
  `memory.max` on its own.
- `--memory-swap` MUST be strictly greater than `--memory`. Equal values (zero
  swap) are the refused shape.
- `max` is the host tier's measured working-set peak plus the resident HOT
  share; `high` is `0.85 × max`; `low` is the working-set baseline
  (`FORGE_WORKING_SET_BASELINE_MB` is its floor).
- The host MUST expose swap for the allowance to mean anything; see
  Requirement "Host swap is provisioned for the tier".

#### Scenario: --memory-swap exceeds --memory by the swap allowance

- **WHEN** `build_podman_args()` produces a forge container's podman argv
- **THEN** `--memory=<N>m`, `--memory-swap=<M>m`, `--memory-reservation=<L>m`
  and `--cgroup-conf=memory.high=<B>` MUST all appear
- **AND** `M − N` MUST be ≥ `sum(HOT tmpfs caps) + 1024`
- **AND** `M` MUST be strictly greater than `N`

#### Scenario: A full HOT tmpfs does not OOM the forge

- **WHEN** a process inside the forge writes more than `memory.max` bytes into
  `/home/forge/src` on a host with at least `swap_allowance` of free swap
- **THEN** the write completes or fails with ENOSPC at the tmpfs cap
- **AND** `memory.events` inside the container reports `oom_kill 0`

#### Scenario: memory.high throttles before memory.max kills

- **WHEN** the forge's `memory.current` exceeds `memory.high`
- **THEN** `memory.events high` increments and the forge continues
- **AND** only reaching `memory.max` with nothing reclaimable invokes the OOM killer

---

### Requirement: Pre-flight RAM check refuses launch on insufficient host RAM
<!-- req-id: 0d67b862 -->

The host available RAM and free swap MUST be measured before every forge
launch via platform-native APIs (Linux: `/proc/meminfo`; macOS: `vm_stat` on
the host and `/proc/meminfo` in the guest; Windows: `GlobalMemoryStatusEx` on
the HOST, never the WSL2 guest's `/proc/meminfo`). If
`mem_available_mb < memory_high_mb × 1.25`, the launch MUST be refused
immediately — no podman invocation occurs. If `swap_free_mb <
swap_allowance_mb`, the launch MUST NOT be refused: the allowance MUST be
clamped to `swap_free_mb`, the HOT caps clamped to fit, and a warning emitted
naming the tier's swap target and how to provision it.

#### Scenario: Refusal emits friendly tray notification + structured accountability log

- **WHEN** the pre-flight check returns `PreflightError::InsufficientRam`
- **THEN** a desktop notification MUST be sent with a human-readable message explaining:
  - how much RAM the forge's `memory.high` needs
  - how much is available
  - how the user can resolve it (close work, lower the tier, or raise host swap)
- **AND** a structured log event MUST be emitted with:
  - `accountability = true`
  - `category = "forge-launch"`
  - `spec = "forge-hot-cold-split"`
  - `host_mem_available_mb = <measured value>`
  - `host_swap_free_mb = <measured value>`
  - `budget = { max_mb, high_mb, low_mb, swap_max_mb, pids_max }`
  - `decision = "refuse"`
- **AND** podman MUST NOT be invoked

#### Scenario: Refusal does NOT invoke podman

- **WHEN** pre-flight returns `InsufficientRam`
- **THEN** no `podman run` command MUST be executed
- **AND** the in-memory container state MUST be reverted (running list de-registered)

#### Scenario: 1.25× headroom factor between MemAvailable and memory.high

- **WHEN** `check_host_ram(mem_available_mb, memory_high_mb)` is called
- **THEN** the threshold MUST be `ceil(memory_high_mb × 1.25)` MB
- **AND** if `mem_available_mb >= threshold`, the result MUST be `Ok(HostRamCheck)`
- **AND** if `mem_available_mb < threshold`, the result MUST be `Err(InsufficientRam)`

#### Scenario: Short swap clamps the allowance and warns

- **WHEN** `swap_free_mb` is below the tier's `swap_allowance_mb`
- **THEN** the launch proceeds with `memory.swap.max = swap_free_mb`
- **AND** the HOT caps are clamped so their sum does not exceed `swap_free_mb + memory_high_mb`
- **AND** the accountability log carries `decision = "degrade"` and the clamped values

#### Scenario: On WSL2 the measurement is the Windows host's

- **WHEN** the tray runs on Windows
- **THEN** `mem_available_mb` and `swap_free_mb` MUST come from `GlobalMemoryStatusEx` on the host
- **AND** the guest's `/proc/meminfo` MUST NOT be the source of either

---

## ADDED Requirements

### Requirement: Host swap is provisioned for the tier

Each platform MUST expose swap to the kernel that runs podman, sized by
`host_swap_mb = 4096 + Σ_concurrent_forges(swap_allowance_mb)` for the host's
tier, and the provisioning MUST be reported and offered, never written
silently.

#### Scenario: Linux host offers a disk swapfile behind zram

- **WHEN** `tillandsias --diagnose` runs on a Linux host whose only swap is zram
- **THEN** it prints `swap:` with the zram size, the disk size (0) and the tier target
- **AND** prints the `btrfs filesystem mkswapfile` (or `fallocate`/`mkswap`) and systemd `.swap` unit commands for a file under `/var/swap`, `pri=10`
- **AND** does not create the file itself

#### Scenario: Windows installer writes absent .wslconfig swap keys with consent

- **WHEN** the installer runs and `%UserProfile%\.wslconfig` lacks `swap`, `swapFile`, `sparseVhd` or `autoMemoryReclaim`
- **THEN** it offers to add exactly the absent keys (`swap=8GB`, `swapFile` under `%LocalAppData%\tillandsias`, `sparseVhd=true`, `autoMemoryReclaim=gradual`) with a `# tillandsias:` comment
- **AND** never overwrites a present `memory`, `swap`, `swapFile` or `processors`
- **AND** re-running with the keys present changes nothing

#### Scenario: macOS guest boots with a dedicated swap device and zram

- **WHEN** the macOS tray provisions the VM
- **THEN** a sparse `vm-swap.img` sized to the tier is attached as a virtio block device and excluded from Time Machine
- **AND** inside the guest `swapon --show` lists that device at `pri=10` and a zram device at `pri=100`
- **AND** the balloon device's target size is not lowered while a forge container is running

---

### Requirement: Forge mounts carry a class

Every mount in a forge profile MUST belong to exactly one class: HOT (tmpfs,
swap allowed), QUARANTINE (tmpfs ≤ 1 MB, credential masking), WARM-RO
(image layer or read-only bind) or COLD (named volume). The swap allowance
MUST be derived from HOT caps only.

#### Scenario: The swap allowance counts HOT mounts only

- **WHEN** a profile carries HOT caps summing to S MB and any number of QUARANTINE, WARM-RO and COLD mounts
- **THEN** `swap_allowance_mb` MUST equal `S + 1024`
- **AND** adding a COLD volume or a WARM-RO bind MUST NOT change it
