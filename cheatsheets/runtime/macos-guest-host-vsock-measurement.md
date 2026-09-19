---
tags: [macos, vsock, virtualization-framework, cfrunloop, measurement-method, exec-guest, seccomp, false-negative]
languages: [bash, rust]
since: 2026-09-19
last_verified: 2026-09-19
sources:
  - order 830-xsk2 (macos-guest-cannot-reach-a-host-native-service)
  - tlatoanis-macbook-air runs 2026-09-19T19:03:01Z and 2026-09-19T19:09:17Z
  - v56.9.19.1 (scripts/derive-vsock-seccomp.sh)
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---
# Measuring a guest→host vsock hop on macOS

@trace spec:cheatsheet-tooling

**Version baseline**: macOS 27.0 / Virtualization.framework, Fedora guest under
VZ, podman 5.x in-guest, socat from `tillandsias-forge-base`
**Use when**: anything inside the macOS guest has to reach a host-native
service, or a vsock/AF_VSOCK measurement on macOS is "failing" and you are about
to widen a timeout.

## The trap in one line

`--exec-guest` **cannot** prove a guest→host vsock connection, and the way it
fails looks exactly like a broken transport.

Virtualization.framework delivers accepted connections to its delegate **only
while the host pumps CFRunLoop**. `--exec-guest` blocks on the control wire and
pumps nothing while a guest command runs, so guest connects sit queued until the
command returns. Measured 2026-08-29: six connects timed out at 2.04–2.06 s each,
then **all six** were accepted in a burst after the command exited.

The 2 s bound is Linux's `VSOCK_DEFAULT_CONNECT_TIMEOUT` — the **guest kernel's**,
not a caller's patience. So the obvious fix does not exist:

> A fixture written on `--exec-guest` reds against working code, and the only
> apparent remedy is to widen a timeout that belongs to the kernel and cannot be
> widened from here. Expect to lose a day to this if you meet it cold.

## The double bind, and the way through

Both obvious doors are shut:

| Context | Pumps CFRunLoop? | Can drive the guest? |
|---|---|---|
| `--exec-guest` | no, not during a command | yes |
| tray (runloop mode) | **yes** | no — it **owns** the VM, so no second control-wire session |

The resolution is to stop trying to drive the guest from outside during the
measurement:

1. **Enable a boot-triggered oneshot in the guest beforehand**, via `--exec-guest`
   (a `systemd` unit, `Type=oneshot`, `WantedBy=multi-user.target`). The VM stops
   when that command returns; the unit will run on the next boot.
2. **Start the tray normally** so it pumps: the `.app` binary with no flags, with
   `TILLANDSIAS_HOST_VSOCK_PORT` and `TILLANDSIAS_HOST_VSOCK_FORWARD_TO` set.
   A bare `target/release` binary lacks `com.apple.security.virtualization` and
   cannot start a VM at all.
3. **Report through the model-cache virtiofs share.** The guest writes its result
   into `/root/.cache/tillandsias/models`; the host reads
   `~/Library/Caches/tillandsias/models` directly. That share is a side channel
   the tray does not own, which is the whole reason both halves of a measurement
   can be captured in one run.

> **Do not leave a permanent fixture reporting through the model cache.** A file
> there trips `scripts/test-macos-model-share-writable.sh`'s empty-cache
> precondition. Fine for a one-off probe; clean up after.

## Require both sides to report

Either side alone is a lie by omission: the host's `ACCEPTED` alone reads as
"it works", and a guest timeout alone reads as "no listener". A passing run looks
like this (2026-09-19T19:09:17Z, all three captured in one run):

```
TRAY   [vz] host vsock: listening on port 42421 — a guest may now connect to CID 2
TRAY   [vz] host vsock: forwarding accepted connections to 127.0.0.1:9999
TRAY   [vz] host vsock: ACCEPTED a guest-initiated connection (fd 13)
HOST   HOST-HTTP-SAW: b'GET /api/version HTTP/1.1'
GUEST  attempt=1 rc=0 BODY=[{"version": "host-native-metal-stub"}]
```

Assert that **the client sees the host's body** — never that a forwarder
started. A relay that starts and answers nothing is indistinguishable, from
inside the guest, from a service that is simply silent.

## AF_VSOCK from a container needs seccomp, not a device

podman's default profile denies `socket` when `arg0 == 40` (`AF_VSOCK`) with an
explicit `SCMP_ACT_ERRNO`. Measured four ways on 2026-09-14: with `/dev/vsock`
**present** in the container the socket is still refused; with the filter relaxed
and **no** device passed it is created.

Use `scripts/derive-vsock-seccomp.sh` (shipped v56.9.19.1), which emits the
installed default with that one rule flipped — never `seccomp=unconfined`, which
disables the whole filter to permit one socket family. Deriving rather than
forking matters: a static copy of the 17,705-byte vendor profile silently stops
tracking podman's default the day podman updates it.

Two failure modes that cost real time:

- **`crun: errno value specified for action SCMP_ACT_ALLOW`** — a flipped block
  must have its `errnoRet`/`errno` fields **removed**. The JSON stays perfectly
  well-formed and every container using it fails to start.
- **`socat[2] W open("/dev/vsock", ...): No such file or directory`** is
  **incidental to socat and not a requirement of AF_VSOCK**. Confirmed
  2026-09-19 under a forwarder that was *serving requests while logging it*.
  Do not go hunting for device passthrough on the strength of this warning.

## Verifying the profile is not just "unconfined in disguise"

"AF_VSOCK works" is equally true of `seccomp=unconfined`, so probe **two**
families across **three** profiles. `NETLINK_AUDIT` is the useful negative: the
default `ERRNO`s it without `CAP_AUDIT_WRITE`, and attempting it needs no
capability, so it separates the filter from the capability set.

| profile | NETLINK_AUDIT | AF_VSOCK |
|---|---|---|
| default | DENIED errno=22 | DENIED errno=1 |
| derived | DENIED errno=22 | **CREATED** |
| unconfined | CREATED | CREATED |

The derived column must sit **strictly between** the other two.

> Two probes were discarded for not discriminating: `unshare -U` succeeded under
> all three profiles, and `swapon` failed identically under all three. A control
> that does not discriminate is not a weaker control — it is not a control.

## Reaching it by name

Agents address `http://inference:11434`, so a working relay that does not answer
to that name does not satisfy the transparency criterion. The forwarder takes the
alias on the enclave network:

```
podman run -d --name tillandsias-vsock-forwarder \
  --network tillandsias-enclave --network-alias inference \
  --cap-drop=ALL --security-opt=no-new-privileges --security-opt seccomp=<derived> \
  --entrypoint socat <forge-base> TCP-LISTEN:11434,fork,reuseaddr VSOCK-CONNECT:2:42421
```

- `build_inference_run_args` **also** claims `--network-alias inference`. For the
  host-native tier the forwarder **replaces** that container; two containers on
  one alias is a coin flip, not a transport.
- Pick the image deliberately: `localhost/tillandsias-inference` has **only
  `sh`** — no socat, nc, python3 or perl. `forge-base` has socat.

## Where the seccomp derivation must run

In **headless, at container-start**. Not in `vz.rs` provisioning, which is
first-boot-only and would never reach an already-provisioned guest — the same
trap the model-cache work paid for on this host. Not in the container's own
entrypoint, because podman applies seccomp **before** the entrypoint runs.
