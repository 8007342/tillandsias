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

---

# SECOND CORRECTION, 2026-09-14 ~20:06Z: IT NO LONGER REPRODUCES, AND MY
# SELINUX EXPLANATION DOES NOT SURVIVE

Retracting the conclusion above. It was stated more confidently than the
evidence now supports.

## What was measured this cycle

With the cache EMPTY and the guest freshly booted, the plain reproduce — the
exact command in the packet's next_action, `-v <share>:...:rw`, no
`--security-opt`, container at uid 1000 — **SUCCEEDED, four times out of four**
(one run at 20:06Z, then three consecutive runs at 20:07Z). The AVC capture ran
correctly this time (`ausearch -m avc </dev/null`) and the only denials in the
window are unrelated: `comm="nft"` on `/dev/ptmx` under `iptables_t`. Nothing
about the model share.

## Why this breaks the SELinux story

The earlier finding rested on one discriminator: plain run DENIED,
`--security-opt label=disable` run SUCCEEDED. That discriminator is gone — the
plain run now succeeds too, so `label=disable` no longer distinguishes
anything, and the inference drawn from it does not stand.

It equally breaks the packet's ORIGINAL claim (ordinary Unix permissions), which
I had already rejected on the mode-0777 arm. The share root is still
`root:root 0755`, the container is still uid 1000, the mount is still virtiofs
with `seclabel`, SELinux is still `Enforcing` — and the write now succeeds,
which none of the three candidate mechanisms predicts.

## What did NOT change, checked rather than assumed

  inference image id      91a800b57328…  created 2026-09-14T07:58:20Z — BEFORE the failing probes
  guest provision.state   2026-09-14T03:53:34Z — no reprovision since
  host share              501:20, mode 0755, empty
  guest mount             model-cache … type virtiofs (rw,relatime,seclabel)
  guest SELinux           Enforcing
  share context           system_u:object_r:container_file_t:s0

So this is not a rebuilt image, not a reprovisioned guest, and not a changed
host directory.

## The honest state

**The mechanism is UNRESOLVED and the defect is NOT CURRENTLY REPRODUCING.** The
measurements recorded earlier in this file happened and are reported accurately;
what does not stand is the EXPLANATION built on them. Something state-dependent
that I have not identified separates the failing regime (~11:56Z) from the
passing one (~20:06Z), and naming it would be another guess wearing a
measurement's clothes.

Do not implement any fix against this packet on the current evidence: there is
nothing reproducible to fix, and three different mechanisms have now been
asserted and withdrawn.

## What this changes downstream

804-deux part (a) was blocked on this. If the inference lane can now populate the
cache through the product's own path, that block may be lifted — but that must
be re-measured through the REAL engine self-install, not through my probe, since
the probe is what just disagreed with itself. That measurement is the next step
and it is cheap.

## The lesson, since it is the third of this shape in one session

A defect that reproduced consistently across several boots, then stopped, with
no identified change, is not a defect that was understood. `label=disable`
flipping the result felt like a mechanism because it was a clean binary
discriminator on a real failure — but a discriminator only identifies a cause if
the failure it discriminates is stable. I should have re-run the bare reproduce
before writing the mechanism into the packet, not after.

---

# THIRD CORRECTION, 2026-09-14 ~20:10Z: IT DOES REPRODUCE — MY PROBE WAS NOT
# THE FAILING OPERATION

The retraction above is itself superseded. The defect is real and reproducing;
what failed to reproduce was MY PROBE, which was not equivalent to the product's
operation.

## The reproducing failure, through the real entrypoint

Empty cache, fresh guest, `podman run ... localhost/tillandsias-inference:latest`
with no `--entrypoint` override:

    [inference] Installing ollama binary (first run)...
    mkdir: cannot create directory '/home/ollama/.ollama/models/.tools/ollama': Permission denied

## Why the probe disagreed — a defect in the packet's own reproduce

The next_action reproduce does a SINGLE-level `mkdir -p <mount>/.tools`. The
shipped code does `mkdir -p "${OLLAMA_MODELS}.tools/ollama"` — TWO levels. The
first level SUCCEEDS; the failure is creating a directory INSIDE the one just
created. So the probe and the product were never testing the same thing, and
"4/4 succeeded" measured an operation that was never broken.

**The packet's stated reproduce is insufficient and must be replaced** with the
nested form, or with the entrypoint itself.

## What is solid, and what is still only a candidate

SOLID, reproducible, measured:

  1. The real path fails at the NESTED mkdir, repeatedly.
  2. A single-level mkdir in the mount ROOT succeeds (uid 1000).
  3. A directory the container creates reads `uid=0 gid=0 mode=755` on a FRESH
     read — the share does not hold non-root ownership.
  4. `chown` in the share returns 0 and does not apply.

So the container can create an entry in the mount root, that entry comes back
root-owned, and the container therefore cannot create anything inside it. The
engine needs exactly that nested create, so the lane cannot start from a clean
cache.

CANDIDATE, NOT SETTLED: within the creating session the same directory listed
`1000 1000` as itself while listing `0 0` as an entry of its parent — a real
disagreement, and the likely proximate reason the nested create was denied. On a
fresh boot both reads agree at `0 0`. Whether the denial is a stale-attribute
effect or simply the root-ownership in (3) is NOT established, and this file
will not claim it is.

## Standing warning on this packet

Three mechanisms have now been asserted and withdrawn here — Unix permissions,
SELinux, and "does not reproduce" — all mine. The common error each time was
naming a cause before re-running the bare failure in the form the product
actually performs it. The next person should start from (1)-(4) above and
resist explaining them until the explanation predicts something new.

## Downstream

804-deux part (a) REMAINS BLOCKED. The cache cannot be populated through the
product's own path.

The image in the guest (91a800b57328, built 07:58Z) predates the fail-loud fix,
so it still emits the old WARN and falls through to the tar error. Once rebuilt,
this same failure announces itself as FATAL at the mkdir with the uid and the
mount owner named — the case that half was landed for.

Cache left EMPTY on both sides after these measurements, deliberately: a
populated .tools hides this defect entirely.
