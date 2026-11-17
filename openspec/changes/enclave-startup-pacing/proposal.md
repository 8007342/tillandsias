## Why

Enclave bringup is already sequential in code (`main.rs:ensure_enclave_for_project`
builds images and starts containers one after another), yet hosts still stall
or crash during it: the operator's Mac VZ guest "hang[s] around creating the
inference container", and macuahuitl "used to crash all the time on their cheap
nvme". Sequential is not paced: each step's gigabytes are still in the page
cache, the drive's SLC cache or a btrfs commit when the next one starts; podman
fetches up to 6 layers at once; the proxy gets a fixed 3 s sleep; the router's
start is never confirmed; and the inference model download overlaps the forge
start. Operator request 2026-11-07: "We definitely need beter orchestration of
the messy startup."

Research (cheatsheets `runtime/container-startup-orchestration.md`,
`runtime/startup-io-memory-pressure.md`) shows every mature orchestrator gates
on readiness, not sleep; serialises heavy I/O (kubelet `serializeImagePulls`);
soft-depends optional services; backs off restarts; and shuts down in reverse.

## What Changes

- Heavy steps (image build, image pull/copy, volume seed, model fetch) run one
  at a time behind one enclave-wide startup lane, and the next heavy step waits
  for I/O and memory pressure (PSI triggers, event-driven) to settle, with a
  per-step deadline.
- Every service start is gated on a readiness check; fixed sleeps are removed.
- Image layer copies are bounded (`image_parallel_copies`).
- Optional services (inference) are soft dependencies: they start after the
  forge is Ready and their failure never blocks it.
- Shutdown runs in reverse start order; failed starts back off.
- The macOS guest bounds dirty writeback in bytes.

## Capabilities

### New Capabilities
- `enclave-startup-pacing`: how the enclave orders, paces and gates its
  bringup and shutdown.

## Impact

`crates/tillandsias-headless` (bringup, container_deps), the image ensure
path, guest provisioning (sysctl, containers.conf), the tray status lines.
Plan rows 2031-75q4, 2031-wqbe, 2031-pd7g, 2031-yu46, 2031-v8si.
