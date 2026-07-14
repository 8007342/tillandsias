# Headless restart wedges guest podman (pause-process/user-namespace mismatch) until `podman system migrate` (2026-07-12)

- class: bug (lifecycle resilience, guest substrate)
- found by: windows meta-orchestration cycle (windows-bullo-fable5-20260712T1940Z),
  live during the order-297 destructive e2e + attended first-login smoke
- status: open
- trace: crates/tillandsias-headless (vault liveness/bootstrap), WSL2 guest,
  tillandsias-headless.service (Restart=always)

## Symptom

On the freshly provisioned Windows guest (v0.3.260712.1), immediately after
`systemctl restart tillandsias-headless` (binary hot-swap), the operator's
FIRST GitHub Login triggered the on-demand vault image build — and every
podman invocation from the new headless process failed in a tight liveness
loop (~every 2s, dozens of processes):

```
Error: fatal error, invalid internal status, unable to create a new pause
process: cannot re-exec process to join the existing user namespace. Try
running "/usr/bin/podman system migrate" and if that doesn't work reboot
[tillandsias-vault] vault image missing — building on demand
[vsock] vault bootstrap after DeliverCredentials failed: Build exited with status exit status: 125
[liveness] check failed: liveness: failed to re-ensure tillandsias-vault: Build exited with status exit status: 125
```

The operator-visible symptom was a login terminal stuck "building the vault
on demand" with no progress and no actionable error.

## Root cause (mechanism)

podman's pause process (rootless namespace anchor under
$XDG_RUNTIME_DIR/libpod/tmp) survived the headless service restart but the
new headless's podman invocations could no longer re-exec into that user
namespace — the documented podman recovery is `podman system migrate`.
Running exactly that in the guest (HOME=/root, XDG_RUNTIME_DIR=/run/user/0)
stopped the three half-started containers and fully recovered podman; the
liveness loop then re-ensured the vault normally.

## Why this matters beyond the trigger

The unit ships `Restart=always`. ANY headless crash/restart (OOM, panic,
upgrade) can leave podman in this wedged state, converting a transient
restart into a permanently broken substrate with an unbounded 2s retry loop
that never self-heals and never surfaces a diagnosis to the tray.

## Fix direction

1. On headless startup (or on the first pause-process-class podman failure),
   run `podman system migrate` once as a self-heal before entering the
   liveness retry loop — it is cheap and idempotent.
2. Rate-limit / cap the vault re-ensure retry loop; after N consecutive
   exit-125s, surface a structured degraded state over the control wire so
   the tray chip and the login lane show an actionable message instead of a
   silent spinner.
3. Consider `ExecStartPre=podman system migrate` in both unit writers as a
   belt-and-braces (needs HOME/XDG env already pinned there per order 274).

## Evidence note for order 274

The journal grep suggested by the order-274 probe (`grep -i "name.*in
use|exit 125"`) FALSE-POSITIVES on this unrelated podman build exit-125.
The 274 signature is specifically the vault container NAME-in-use race, not
build exit codes. Record 274 evidence from the name-in-use pattern only.

## Repro

Fresh WSL2 provision → `systemctl restart tillandsias-headless` in-guest →
trigger any podman-touching flow (GitHub login / lane launch) → observe
pause-process fatals + exit-125 loop; `podman system migrate` recovers.
