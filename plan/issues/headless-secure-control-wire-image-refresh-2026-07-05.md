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
