## Context

Audit (2026-11-07) of `ensure_enclave_for_project`: cleanup → container_deps
topo order (networks, CA, proxy + fixed 3 s sleep, vault, nix-cache) →
`ensure_versioned_images` for router, git, inference, forge in a sequential
loop → token gate → router (start not confirmed) → mirror lock → git → ssh
sidecar → inference start (awaited; readiness spawned in background) →
`gate_forge_launch` (git 1200 s, others 120 s). There is no enclave-wide
podman semaphore; locks are per resource. The existing ordering is right; the
pacing and the readiness checks are what is missing.

## Decisions

1. **One startup lane, not more parallelism.** A single async mutex (or
   semaphore of 1) around heavy steps, shared by every project's bringup in one
   headless process. Matches the containers/storage layer lock, which already
   serialises commits, and kubelet's `serializeImagePulls: true` default.
2. **Settle by pressure, by event.** Before the next heavy step, wait until
   `/proc/pressure/io` and `/proc/pressure/memory` are under threshold, using a
   PSI trigger and `poll()` (no polling loop, per the project's no-polling
   rule). The starting threshold is io some avg10 < 10%, full < 2%, and memory
   full < 2%; it gets tuned from measurements. If PSI is not available, fall
   back to one bounded settle per step. Hard per-step deadline; on expiry
   proceed and log `bringup: settle-timeout step=<n>`.
3. **Readiness checks replace sleeps.** Proxy: TCP connect on 3128. Router: a
   container-running check plus its health check. Each has its own deadline and
   its own status line.
4. **Optional means soft.** Inference (and model fetch) starts after the
   forge reports Ready, inside the same lane, so it never competes with the
   forge's first start. Its failure is reported, not fatal.
5. **Bounded layer copies.** `image_parallel_copies = 2` in the containers.conf
   we provision (Linux user runtime, macOS/Windows guests).
6. **macOS guest writeback.** `vm.dirty_background_bytes=64M`,
   `vm.dirty_bytes=256M` in the guest. These are measured starting values, not
   vendor guidance.
7. **Reverse-order shutdown and restart backoff** mirror systemd's semantics.

## Risks

- Cold bringup gets slower in wall-clock time on fast hosts. Mitigation: the
  settle returns immediately when pressure is already low, and every step
  records its timing, so the cost is measured.
- A PSI threshold that is too strict waits until the deadline every time. The
  timing records expose this; tune the threshold from them.
