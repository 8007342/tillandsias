# Init Fails on systemd-resolved Hosts — DNS in Build Containers

**Status:** `ready`
**Owner:** linux
**Date:** 2026-06-27
**Kind:** bug / enhancement
**Trace:** `spec:install-progress`

## Symptom

`tillandsias --init` fails during `build-git` image build:

```
WARNING: fetching https://dl-cdn.alpinelinux.org/alpine/v3.20/main: DNS lookup error
ERROR: unable to select packages: bash (no such package) ...
Error: building at STEP "RUN apk add --no-cache ...": exit status 8
FAILED git: Build exited with status exit status: 8
```

## Root Cause

On Fedora (and any systemd-resolved host), `/etc/resolv.conf` is a symlink to
`/run/systemd/resolve/stub-resolv.conf` which sets `nameserver 127.0.0.53`. This
is the systemd-resolved stub listener on the host's loopback. From inside a
`podman build` ephemeral container, `127.0.0.53` is the container's own loopback
— not the host's — so DNS resolution fails.

The actual upstream DNS servers are visible via `resolvectl status` but are not
automatically propagated to containers.

## Workaround (user-applied 2026-06-27)

Added to `~/.config/containers/containers.conf`:

```toml
[network]
dns_servers = ["209.18.47.61", "209.18.47.63", "1.1.1.1"]
```

After this change, `podman run --rm alpine:3.20 nslookup dl-cdn.alpinelinux.org`
resolves correctly (podman/pasta forwards to the configured servers).

## Fix: Auto-detect and patch during --init

The `--init` flow already writes to `~/.config/containers/containers.conf`
(for proxy settings). It should also:

1. Detect if `/etc/resolv.conf` nameserver is a loopback address (`127.*` or `::1`).
2. If so, run `resolvectl status` (or parse `/run/systemd/resolve/resolv.conf`)
   to extract the actual upstream DNS servers.
3. Add `dns_servers = [...]` to the `[network]` section of containers.conf if
   not already present.
4. Print a one-line note: `[tillandsias] Configured DNS for container builds
   (host uses systemd-resolved stub at 127.0.0.53)`.

Fallback: if `resolvectl` is unavailable, use `["1.1.1.1", "8.8.8.8"]` and warn.

## Implementation Notes

- Check in `crates/tillandsias-headless/src/vault_bootstrap.rs` or the init
  path in `main.rs` near where `containers.conf` is written.
- The detection heuristic: `nameserver 127.` in `/etc/resolv.conf` content.
- The `dns_servers` key is a TOML array under `[network]`; merge rather than
  overwrite (user might have existing entries).
- Add a litmus test: `--init` on a systemd-resolved host completes without
  DNS-related build failures.

## Exit Criteria

- `tillandsias --init` on a Fedora Silverblue host with systemd-resolved
  completes without DNS errors in container builds
- `~/.config/containers/containers.conf` after init includes `dns_servers`
  populated from the actual upstream resolver when 127.0.0.53 is detected
- Litmus test: `tillandsias --headless /tmp/t 2>&1 | grep 'dns'` shows
  the note line when the stub is detected
