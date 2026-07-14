# Guest/container metrics must cross the VM boundary idiomatically (control wire), not via hacks

- Date: 2026-07-13
- Class: enhancement (observability gap)
- Filed by: macos-osx-next meta-orchestration cycle 2026-07-13T22:43Z (operator-directed resource-monitoring pass)
- Related: spec:observability-metrics, crates/tillandsias-metrics, crates/tillandsias-headless/src/metrics_server.rs, order 315 (git-mirror audit), methodology/multi-host-development.yaml `idiomatic_layers_for_agents` (order 271)
- Pickup: linux (guest-side implementation), then macos/windows tray consumption

## Problem

The operator wants to know whether host or guest resources bottleneck a
BigPickle forge cycle, and whether more forge pieces (checkout, pull cache,
proxy cache, router state, git-mirror storage) would benefit from ramdisk.
Today there is NO way to answer this without jumping the VM boundary:

- `tillandsias-headless` already has a Prometheus metrics server
  (`metrics_server.rs`, hand-rolled HTTP/1.1 at `GET /metrics`, backed by
  `tillandsias-metrics` — CPU, memory, disk-usage, disk-I/O from
  `/proc/diskstats`, PSI from `/proc/pressure`). It listens on **TCP inside
  the guest**.
- On macOS the only host↔guest channel is the **virtio-vsock control wire**
  (`CONTROL_WIRE_VSOCK_PORT`). The TCP `/metrics` endpoint is unreachable
  from the host without an ssh/port-forward hack, which order-271 policy
  forbids ("a forensic need the layer cannot meet is a product gap to FILE").
- The per-container view (proxy, cache, router, vault, git-mirror, forge —
  all podman containers inside the guest) is not sampled at all;
  `tillandsias-metrics` samples the guest system level only.

Observed on macOS host (2026-07-13, cold e2e, host = 10-core M-series,
16 GiB RAM; guest VZ config = **4 CPUs / 4 GiB** per
`crates/tillandsias-vm-layer/src/vz.rs:941`): from the host we can see only
the tray process totals (Virtualization.framework runs in-process) —
aggregate CPU/RSS of the whole VM, VM-dir disk growth. Which container
inside the guest is hot, whether guest memory pressure (PSI) is climbing,
and which paths do the most I/O are all invisible.

## Ask (Linux-implementable, no boundary hacks)

1. **Per-container sampling in guest headless**: extend the sampler with
   per-container CPU/mem/blkio (cgroup v2 under
   `/sys/fs/cgroup/machine.slice/libpod-*` or `podman stats --format json`)
   for the named service containers: proxy, cache, router, vault,
   git-mirror, forge lanes.
2. **Expose over the control wire**: a `MetricsSnapshot` request/response
   (or streamed vm-status metric lines) on the existing vsock wire so macOS/
   Windows trays and `--diagnose --json` can read it without TCP. The
   existing `/metrics` TCP endpoint stays for Linux-local scrapes.
3. **Hot-path I/O attribution**: per-mount read/write byte+op counters for
   the decision-relevant paths: `/home/forge/src` (virtiofs on macOS),
   the pull cache root, `/opt/cheatsheets` (tmpfs), git-mirror storage,
   proxy cache dir. This is the direct input to
   plan/issues/forge-hot-path-placement-metrics-2026-07-13.md.
4. **Tray surface**: minimal — `--diagnose --json` gains a `metrics` block;
   dashboards can come later.

## Verifiable closure

- litmus: a control-wire `MetricsSnapshot` round-trip on a booted guest
  returns parseable per-container samples for every running service
  container, and a collection failure surfaces as an error field (never a
  fabricated healthy sample, per spec:observability-metrics).
