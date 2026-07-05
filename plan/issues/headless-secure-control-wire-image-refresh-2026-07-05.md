# Linux: refresh the guest headless image to the secure-control-wire-capable release — 2026-07-05

- class: release+bug-fix (Linux guest image)
- filed: 2026-07-05
- owner: linux
- pickup_role: linux
- status: ready
- trace: spec:vsock-transport, plan/issues/secure-channel-maturity-ladder-2026-07-04.md

## Problem

The macOS tray host can now upgrade the host↔guest control wire with
`tillandsias-secure-channel` behind `TILLANDSIAS_SECURE_CONTROL_WIRE=on`, but
the guest image currently in the macOS VM still behaves like a plaintext-only
listener. A secure GitHub-login smoke on the packaged app fails with:

```text
secure control wire handshake failed: early eof
```

That means the host initiator is speaking the secure protocol, but the guest
headless image being launched by the VM does not yet have the matching responder
path deployed.

## Evidence

- Packaged macOS app build succeeds and auto-boots the VM.
- `--github-login` with `TILLANDSIAS_SECURE_CONTROL_WIRE=on` reaches the control
  wire, then fails with `secure control wire handshake failed: early eof`.
- The host-side tray source now contains the secure-or-raw opener; the guest
  image is the missing half.

## Next step

Update the guest image/deployment path so the in-VM headless binary that macOS
boots includes the secure-control-wire responder path, then re-provision the
macOS guest and rerun the secure login/list/forge smoke.

## Exit criteria

- Secure GitHub login smoke on macOS reaches the credential prompts with the
  secure flag enabled.
- Secure remote-project listing and forge launch succeed over the same wire.
- The guest image is known to match the source tree carrying the secure responder.


## LINUX INTEGRATION 2026-07-05 (loop iter 3)

The guest secure-control-wire responder is now on **linux-next**
(`crates/tillandsias-headless/src/vsock_server.rs` + Cargo.toml dep on
`tillandsias-secure-channel`), integrated from macOS's osx-next work (c6c56981),
reviewed as the linux owner of the headless crate. Applied as identical content (not
a cross-branch cherry-pick) so it converges cleanly when the branches next merge.

Security review (PASS):
- `maybe_secure_stream` is a genuine NO-OP when `TILLANDSIAS_SECURE_CONTROL_WIRE` is
  OFF/absent/empty (plaintext exactly as before — the flip is opt-in, off changes
  nothing).
- When ON it runs `server_handshake(stream, channel_psk(VERSION, WIRE_VERSION,
  HopId::HostGuest))` — same PSK inputs as the host initiator, so a version mismatch
  or a plaintext peer is rejected (anti-downgrade).
- FAIL-CLOSED: a handshake error closes the connection (returns before any envelope
  is read → no PtyOpen served). An unrecognized flag value is an Err, not a silent
  downgrade — pinned by the new unit test
  `secure_control_wire_flag_defaults_off_and_fails_closed` + litmus
  `secure-control-wire-guest-responder-shape`.
- Builds + tests green under `--features vault,listen-vsock` (the in-VM guest build).

## AVAILABLE NOW — no release needed (operator clarification 2026-07-05)

macOS embeds the **cross-compiled linux guest binary** into the macOS app (the same
way the tray embeds Containerfiles) and injects it into the VM — it does NOT boot a
released artifact. So the responder is available to macOS the moment it lands on
`linux-next` (commit a6b4d5d7); no `release.yml` dispatch is required, and macOS is
NOT blocked on linux.

Status: **linux code DONE + on linux-next**. Remaining is macOS-side only: rebuild
with the current linux-next source embedded, then rerun the secure login/list/forge
smoke with `TILLANDSIAS_SECURE_CONTROL_WIRE=on` (the M1→M2 gate evidence for the
host↔guest hop on macOS).
