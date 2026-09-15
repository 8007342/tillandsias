# 830-xsk2 — the in-guest hop is blocked by SECCOMP ALONE, not by the device

Host: macos-tlatoanis-macbook-air. Measured 2026-09-14 in the live guest.

The packet's prior claimant left the route undecided and said, correctly, to
measure the device question before assuming the container route. Measured — and
the answer is neither of the two options as framed.

## The four arms

All four run the SAME image and the SAME `socat VSOCK-CONNECT:2:42421`, varying
only the podman flags. `--cap-drop=ALL --security-opt=no-new-privileges` are the
real profile's flags (`remote_projects.rs` args list, `main.rs`
build_inference_run_args).

| arm | flags | result |
|---|---|---|
| A | profile flags only | `socket(40, 1, 0): Operation not permitted` |
| B | + `--device /dev/vsock` | `socket(40, 1, 0): Operation not permitted` |
| C | + `seccomp=unconfined` + device | socket OK; `connect(... cid:2 port:42421): Connection timed out` |
| D | + `seccomp=unconfined`, NO device | socket OK; `connect(...): Connection timed out` |

The guest root namespace does have the node: `crw-rw-rw-. 1 root root 10, 261
/dev/vsock`.

## What this settles

**B is the load-bearing arm.** With the device node present INSIDE the
container, `socket(AF_VSOCK)` is still refused. So the device is not the
barrier, and `--device /dev/vsock` does not need to be added to anything.

**D is the one that changes the design.** With seccomp relaxed and NO device
passed, the socket is created and the connect reaches CID 2. `socat` still warns
`open("/dev/vsock"): No such file or directory` and proceeds — that open is
incidental to socat, not a requirement of AF_VSOCK.

So the container route costs exactly ONE change — a seccomp allowance for
AF_VSOCK socket creation — and NOT the device passthrough, and NOT the
`--add-host inference:<gateway>` alternative that the packet warned "touches the
shared container profile and therefore every consumer".

## ETIMEDOUT is the expected result here, not a failure

`Connection timed out` in arms C and D is the signature this packet established
on 2026-08-29: the guest's vsock stack ROUTES to CID 2 and transmits, and
nothing answers. Under `--exec-guest` nothing CAN answer — Virtualization.
framework retains guest connection requests and delivers them only when the host
pumps CFRunLoop, and `--exec-guest` pumps nothing while a guest command runs.
The 2s bound is Linux's `VSOCK_DEFAULT_CONNECT_TIMEOUT`, not a probe's patience.
Reading these two arms as "still broken" would repeat exactly the confusion the
prior claimant wrote the constraint down to prevent.

## Recommendation, and what NOT to do

Do NOT ship `--security-opt seccomp=unconfined`. It was the right instrument to
ISOLATE the cause and is the wrong one to fix it: it disables the whole filter
for every syscall, to permit one socket family.

The narrow shape: a custom seccomp profile identical to podman's default plus
`socket` with `AF_VSOCK`, applied ONLY to the forwarder container. The
forwarder is a dedicated single-purpose container, so this does not touch the
profile of any other consumer — which removes the objection that made the
`--add-host` alternative look comparable. Every agent container keeps the
default filter.

## Not yet established

The runtime proof of the whole hop still cannot come from `--exec-guest`. It
needs a host context that pumps continuously (tray mode). That constraint is
inherited, not re-measured here; these four arms measure only whether a
container CAN open AF_VSOCK, which was the open question.
