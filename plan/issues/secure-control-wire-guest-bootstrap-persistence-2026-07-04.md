# Secure control wire guest bootstrap does not persist across boots

Status: blocker
Date: 2026-07-04

## What we proved

- The macOS tray now packages the matching Linux guest binary into the `.app`.
- The host-generated `cidata.iso` contains the expected secure flag when
  `TILLANDSIAS_SECURE_CONTROL_WIRE=on` is set on the host.
- `--exec-guest` over the plain control wire still works, so the VM is booting
  and the guest control plane is reachable.

## What still fails

- `TILLANDSIAS_SECURE_CONTROL_WIRE=on ./dist/Tillandsias.app/Contents/MacOS/tillandsias-tray --github-login`
  still dies with:
  - `vsock connect: secure control wire handshake failed: early eof`
- A fresh `--provision` run did not change the behavior.
- Inside the guest, `/etc/systemd/system/tillandsias-headless.service` still lacks
  `Environment=TILLANDSIAS_SECURE_CONTROL_WIRE=on`.

## Evidence

- Host ISO content check:
  - `strings ~/Library/Application Support/tillandsias/cidata.iso`
  - shows `Environment=TILLANDSIAS_SECURE_CONTROL_WIRE=on`
- Guest service file check:
  - `--exec-guest /bin/cat /etc/systemd/system/tillandsias-headless.service`
  - shows `Environment=TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200`
  - does not show the secure-control-wire env line
- Fresh rootfs provisioning did not change the outcome.

## Likely cause

- The guest bootstrap path that writes the systemd unit is not actually
  persisting the secure env line into the running guest image, even when the
  host-side ISO is regenerated.
- This is likely a cloud-init / bootstrapping persistence issue in the guest
  image or a post-provision step overwriting the unit.

## Next steps for Linux workers

- Trace the guest bootstrap path that creates `/etc/systemd/system/tillandsias-headless.service`.
- Confirm where the plain unit content is coming from after reprovision.
- Make the secure env line land in the guest image reliably, or move the secure
  mode selection into a boot-time mechanism that cannot be stale.
