---
tags: [io-pressure, psi, qlc-nvme, dirty-writeback, btrfs, podman-storage, startup-pacing]
languages: [ini, bash]
since: 2026-11-07
last_verified: 2026-11-07
sources:
  - https://docs.kernel.org/accounting/psi.html
  - https://docs.kernel.org/admin-guide/sysctl/vm.html
  - https://docs.kernel.org/admin-guide/cgroup-v2.html
  - https://btrfs.readthedocs.io/en/latest/Administration.html
  - https://github.com/containers/common/blob/main/docs/containers.conf.5.md
  - https://github.com/containers/storage/blob/main/docs/containers-storage.conf.5.md
  - https://www.anandtech.com/show/16461/the-samsung-870-qvo-review
authority: medium
status: current
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
pull_recipe: see-section-pull-on-demand
---

# Startup I/O and memory pressure: pacing heavy container work on small disks

**Use when:** several image builds, layer copies, volume writes and container
starts happen back to back, and the host (a QLC NVMe laptop, a VZ guest on a
laptop SSD) stalls, OOMs or crashes during enclave bringup.

## Why back-to-back is not enough

Serial steps still overlap at the disk: the page cache absorbs a step's writes
and flushes them later, so step N+1 starts while N's gigabytes are still being
written.

- **QLC SLC-cache exhaustion** (secondary source, review measurements): a
  sustained write fills the drive's SLC cache, then throughput falls from
  ~GB/s to the native QLC rate (on the order of 100 MB/s), recovering only
  after minutes of idle. A multi-GB build plus a model download can cross it.
- **btrfs commits every 30 s by default** (`commit=` mount option), turning
  steady writes into bursts.
- **Dirty-page limits** are ratios of RAM by default (`vm.dirty_ratio`,
  `vm.dirty_background_ratio`); on an 8 GiB guest that is hundreds of MB to
  GBs of unflushed data. `vm.dirty_bytes` / `vm.dirty_background_bytes` cap
  it in absolute terms so writeback starts earlier and stalls are shorter.
- **Parallel layer copies**: containers.conf `image_parallel_copies` (0 means
  the default of 6 in containers/image) fetches several layers at once.

## Gate on pressure, by event, not by sleeping

Pressure Stall Information (`/proc/pressure/{cpu,memory,io}` and per-cgroup
`*.pressure`) reports the share of time tasks stalled. A process can
**register a trigger** (write `some 150000 1000000` to the file and `poll()`
for `POLLPRI`) and is woken when the threshold is crossed — no polling loop.

Suggested gate before starting the next heavy step (derived, not vendor
guidance): io `some avg10 < 10%` and `full avg10 < 2%`, memory `full avg10 < 2%`;
wait on a trigger, with a hard per-step deadline.

## Other levers

- cgroup v2 `io.weight` / systemd `StartupIOWeight=` give latency-sensitive
  services priority over a build during startup.
- `memory.low` protects the forge's working set (already used: 1913-fh6l).
- One storage mutation at a time: builds, pulls and `podman system` operations
  share the containers/storage layer lock; running them concurrently mostly
  adds contention.

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: several upstream doc sites; the summary above carries the claims used here.
> See `cheatsheets/license-allowlist.toml` for per-domain authority.

### Source

- **Upstream URL(s):**
  - `https://docs.kernel.org/accounting/psi.html`
  - `https://docs.kernel.org/admin-guide/sysctl/vm.html`
- **Archive type:** `single-html`
- **Expected size:** `~2 MB`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/startup-pressure-docs/`
- **License:** vendor documentation licences (see each site)
- **License URL:** see each upstream URL

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET_DIR="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/startup-pressure-docs"
mkdir -p "$TARGET_DIR"
curl --fail --silent --show-error -L "https://docs.kernel.org/accounting/psi.html" -o "$TARGET_DIR/0.html"
curl --fail --silent --show-error -L "https://docs.kernel.org/admin-guide/sysctl/vm.html" -o "$TARGET_DIR/1.html"
```

### Generation guidelines (after pull)

1. Read the pulled files for the exact option names and defaults cited above.
2. If your project needs a project-specific version, generate it at `<project>/.tillandsias/cheatsheets/runtime/startup-io-memory-pressure.md` using `cheatsheets/TEMPLATE.md`.
3. The generated cheatsheet MUST set frontmatter: `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`, `committed_for_project: true`.
4. Cite the pulled sources under `## Provenance` with `local: <cache target above>`.

## Provenance

Retrieved 2026-11-07 by research agents at the operator's request, after the
operator observed that "creating all the containers one after another at launch
is quite the stress to the vm" and that macuahuitl "used to crash all the time
on their cheap nvme". Kernel and containers docs are primary. The QLC figures
come from a secondary review site (hence `authority: medium`). The PSI
thresholds are a derived starting point to be measured, not vendor guidance.
