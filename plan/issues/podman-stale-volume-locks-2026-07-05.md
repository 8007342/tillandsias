# Podman stale volume-lock errors in the guest — 2026-07-05

- class: research (forge runtime) — needs root-cause before it becomes noise/blocker
- filed: 2026-07-05
- owner: linux
- status: ready
- pickup_role: linux
- trace: spec:default-image; likely interacts with order 179 (persistent tool-cache named volume)
- host-context: macOS Apple Silicon guest (Fedora 44 aarch64), tray v0.3.260704.1

## Symptom (observed this cycle)

Listing images in the guest over `--exec-guest` emitted, before the normal output:

```
level=error msg="Cleaning up volume (8610e03732a9…): freeing lock for volume
  8610e03732a9…: freeing lock for volume …: no such file or directory"
level=error msg="Cleaning up volume (8a8488d956e6…): freeing lock for volume
  8a8488d956e6…: no such file or directory"
```

The referenced volume ids do not exist (stale). The command still exited 0, so this
is currently **advisory noise**, but it points at leaked/half-created volume state.

## Why capture now

Order 179 just introduced a **persistent per-project tool-cache named volume**.
Stale volume locks appearing right after 179 landed are a plausible interaction:
a named volume created then `--rm`'d, or created under a lock dir that the guest
tmpfs (`/run/user/1000`) does not persist across boots, would leave dangling lock
references. If first-run tool installs (`forge-firstrun-tool-migration`) come to
depend on that volume, a stale-lock failure would turn advisory noise into a real
first-run install failure.

## Smallest next action / verifiable closure

1. Reproduce deterministically: `podman volume ls`, `podman volume ls --format
   '{{.Name}}'`, and inspect `<graphroot>/volumes` + the lock dir in the guest to
   identify what created ids `8610e0…` / `8a8488…`.
2. Decide: is the 179 named volume created with a lifecycle that survives the
   forge `--rm` and VM reboots, or is its lock dir on a tmpfs that is wiped?
3. Add a guest-startup reconcile (or `podman volume prune` of unreferenced locks)
   so the error class cannot appear, and a litmus asserting a clean
   `podman volume ls` after a boot+forge+exit cycle.
