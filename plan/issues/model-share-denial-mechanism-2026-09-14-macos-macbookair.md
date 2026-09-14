# 1183-j9dk — the model-share denial is SELinux, not Unix permissions

Host: macos-tlatoanis-macbook-air. Measured 2026-09-14 against an EMPTY
`~/Library/Caches/tillandsias/models`, which is the only regime in which this
defect exists.

## The correction

The packet I filed states the mechanism as: virtiofs presents the share
root-owned, the container runs as uid 1000, "and ordinary Unix semantics then
forbid it creating an entry." **That is wrong**, and every one of the three
candidate fixes it proposes is aimed at the wrong layer as a result.

Measured, same directory, same container image:

| probe | result |
|---|---|
| container uid 1000 `mkdir` in share, mode 0755 | denied (reproduce confirmed) |
| same, on a guest-created subdir at mode **0777** | **still denied** |
| `chown 1000:1000` inside the share | **exits 0, changes nothing** |
| `chmod` on the share **root** | EPERM |
| `chmod` on a subdir **of** the share | succeeds, and applies |
| container uid 1000 `mkdir`, `--security-opt label=disable` | **succeeds** |

A directory at mode 0777 that refuses uid 1000 is not DAC. The guest is
`Enforcing`, the share carries `system_u:object_r:container_file_t:s0`, and
relaxing the container's SELinux confinement is what flips the result. The
denial is SELinux confinement of the container against this mount.

## What this rules out

- **Shape 1 (present the share as uid 1000) is not merely hard, it is absent
  from the platform API.** `VZSharedDirectory` exposes exactly
  `initWithURL_readOnly`, `URL` and `isReadOnly` — there is no ownership
  parameter to set. Source-read of objc2-virtualization 0.2.2.
- **Shape 2 (guest-side chown after mount) is a trap.** `chown` on this mount
  returns success and does not apply. Implemented as written it would have
  looked done, passed a careless check, and fixed nothing — and the ownership
  it targets is not the cause anyway.
- **Shape 3 (userns mapping)** addresses uid, which the 0777 arm shows is not
  the discriminator.

## What is still open

The exact AVC was not captured. `ausearch -m avc` **hangs** reading stdin under
`--exec-guest` (it stalled two probes to a hard kill before it was isolated;
run it with `</dev/null`). The `dmesg` fallback returned nothing, but that arm
was written `dmesg | grep | tail -5 || echo "no-avc-in-dmesg"`, where `tail`
always exits 0 — so the negative branch could never print, and the result is
UNCAPTURED, not absent. Do not read it as "there is no AVC".

Naming the permission is the next step, because it decides between a mount-time
SELinux context in the fstab line vz.rs writes, a relabel at container-run time
(`:z`/`:Z`), and a targeted policy allowance. The share is already
`container_file_t:s0`, so a plain `context=` mount option would be a no-op —
which is why the AVC matters rather than being a formality.

## Why the Linux lane never saw it

On Linux the model cache is a podman VOLUME, which podman labels and chowns as
a matter of course (order 313). The macOS lane replaced the volume with a
virtiofs share (804-deux part 1) and inherited neither behaviour. It only bites
before `.tools/` exists, so any host whose cache predates the share is immune.

## Landed this cycle

The independently-scorable half: the entrypoint's `mkdir` failure is now fatal
where it happens and names the ownership, instead of surfacing four lines later
as `tar: ...: Cannot open: No such file or directory` preceded by "will retry
next launch (non-fatal)" — a retry that could never succeed. Guarded by
`scripts/test-inference-mkdir-fatal-1183-j9dk.sh`, 7 arms including a mutation
control; falsified at 0 passed / 5 failed against the unfixed entrypoint.

Host state verified clean after every probe: share empty, `501:20`, `0755`, no
scratch directories left on either side.
