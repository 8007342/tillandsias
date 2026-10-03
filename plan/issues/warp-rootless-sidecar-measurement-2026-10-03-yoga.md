# WARP rootless sidecar measurement — 1506-euvq (yoga, 2026-10-03)

- packet: 1506-euvq (milestone 1506-3xu7, Decision 6 of
  `openspec/changes/fleet-messaging-poc/design.md`)
- host: yoga (Fedora Silverblue 44.20261003.0), linux, rootless podman
- branch: `work/1506-euvq` from `origin/linux-next` @ `49a7669c7`
- scope limit: NO enrollment. There is no Zero Trust org and no service
  token; nothing here logged in, registered, wrote an mdm.xml, or called a
  Cloudflare API with credentials. Everything up to enrollment is measured.
- instrument: `scripts/research-warp-sidecar-rootless.sh` (new, the packet's
  exit-criterion script) plus `images/warp/{Containerfile,entrypoint.sh}`.
  Every container, volume, network and image created was removed by exact
  name or id (verified empty at the end, see § Cleanup).

## Recorded outcome

**`outcome:tun-denied-rootless`** — for the posture the packet names
(`--network container:<router> --cap-drop=ALL --cap-add=NET_ADMIN
--device /dev/net/tun --sysctl net.ipv4.conf.all.src_valid_mark=1
--userns=keep-id --user 0`).

It is posture-specific and repairable, not terminal. Two independent causes,
each isolated by a one-flag differential:

1. **SELinux** (`container_t` cannot open `tun_tap_device_t`; the boolean
   `container_use_devices` is `off`): `--device /dev/net/tun` passes the node
   but `open()` is EACCES. `--security-opt label=disable` clears it — the
   router itself already runs with `label=disable`
   (`crates/tillandsias-headless/src/main.rs:6264`).
2. **User-namespace ownership of the shared netns**: `--userns=keep-id`
   gives the sidecar its OWN user namespace (same mapping, different
   namespace), so its NET_ADMIN does not cover the owner's network
   namespace: `ioctl(TUNSETIFF): Operation not permitted`, nft
   `Operation not permitted`, and crun cannot even write the
   `src_valid_mark` sysctl (rc 126, so the packet's launch line never
   starts a container at all). `--userns=container:<owner>` (join the
   owner's keep-id namespace) clears all three.

Under the **repaired posture** (packet posture with
`--userns=container:<owner> --security-opt label=disable`), no
pre-enrollment refusal fires: TUN created and addressed, nftables table and
hook chain created, sysctl applied, `warp-svc` up as PID 1 under
`--read-only`, `warp-cli status` answers. The two outcomes that remain —
`mesh-ip-acquired` vs `registers-no-mesh-ip` (and `firewall-refused`, whose
vendor trigger only fires at connect) — are facts about a REGISTERED client
and need enrollment. The script prints
`outcome-pending:enrollment-required:operator-minted-service-token-mdm.xml`
as its last line in that case rather than inventing a token.

A third blocker, independent of rootlessness, applies to the REAL router:
its namespace has no route to Cloudflare (§ fact 9).

## Regime

```
$ podman version --format '{{.Client.Version}}'      -> 5.8.7   (rc=0)
$ uname -r                                            -> 7.2.8-200.fc44.x86_64   (rc=0)
$ podman info --format '{{.Host.NetworkBackend}} ... rootless={{.Host.Security.Rootless}} cgroup={{.Host.CgroupsVersion}}'
  -> netavark /usr/bin/pasta ... rootless=true cgroup=v2   (rc=0)
$ getenforce (via script regime line)                 -> Enforcing
$ ls -l /dev/net/tun                                  -> crw-rw-rw-. 1 root root 10, 200
$ getsebool container_use_devices                     -> container_use_devices --> off   (rc=0)
client (inside image): warp-cli 2026.7.1377.0
```

## The ten facts that matter (measurements; command, then rc on its own line)

1. **The vendor package installs and runs without systemd.**
   `podman build -t localhost/warp-probe-1506:2026.7.1377.0 images/warp`
   rc=0. postinst prints `System has not been booted with systemd as init
   system (PID 1). Can't operate.` and `policy-rc.d returned 101, not running
   'start warp-svc.service'` and continues. It pulls 246 packages
   (systemd, systemd-sysv, libwebkit2gtk-4.1-0, flutter GUI libs): image
   888 MB (`podman images`). `package-refuses-container` is excluded.

2. **The vendor's own unit asks for more than NET_ADMIN.**
   `/lib/systemd/system/warp-svc.service` (read inside the image):
   `CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE
   CAP_DAC_OVERRIDE CAP_NET_RAW CAP_SETUID CAP_SETGID`. Pre-enrollment the
   daemon ran with NET_ADMIN alone; whether connect needs NET_RAW or
   NET_BIND_SERVICE is an enrollment-time question (it would need a second
   named capability, which `weakening_hardening_flag` does not refuse but
   972-6vaj's one-justification-per-cap rule must cover).

3. **`warp-svc` starts as PID 1 under `--read-only` and `warp-cli` answers,
   with or without NET_ADMIN.** Repaired posture, internal owner (run F3):
   `arm:svc-no-netadmin rc=0`, `arm:svc-no-netadmin-status rc=0`,
   `arm:svc-netadmin rc=0`, `arm:svc-netadmin-status rc=0`, both printing
   `Status update: Unable` / `Reason: Registration Missing due to: Daemon
   Startup`. Writable paths it needs: tmpfs `/run` (IPC socket
   `/run/cloudflare-warp/warp_service`), tmpfs `/var/log/cloudflare-warp`,
   volume `/var/lib/cloudflare-warp` (settings, registration, mdm.xml).
   It logs `Firewall engine running` / `Aligning firewall state` /
   `Firewall unloaded` at start — "Failed to start firewall" appears in none
   of the 8 evidence directories' daemon logs (F1's sidecars never
   started, so 7 runs contributed a running daemon) (`cat warp-research.*/svc-*.log | sed <strip
   ANSI> | grep -c -i 'failed to start firewall'` → `0`). Pre-registration
   the firewall has nothing to load, so this does not exclude
   `firewall-refused` at connect.

4. **Packet posture: TUN denied (the recorded outcome).** Run F1:
   `arm:packet-tun-netadmin rc=1` → `open: Permission denied`;
   `arm:packet-tun-no-netadmin rc=1` → same. Inside such a container,
   `test -c /dev/net/tun` is false (`arm:svc-netadmin-tun-visible rc=1` on
   run R1) and `ls -lZ /dev/net/tun` is `Permission denied`.

5. **SELinux is the first cause** (scratch matrix, same image, own netns):
   `podman run --rm --cap-drop=ALL --cap-add NET_ADMIN --device /dev/net/tun --user 0 --userns=keep-id ... ip tuntap add dev probe0 mode tun`
   → `open: Permission denied` (M1);
   the same plus `--security-opt label=disable` → `tun-ok`, and the node
   reads `system_u:object_r:tun_tap_device_t:s0` (M1L). Identical pair on a
   throwaway `--internal` bridge (M2 / M2L).

6. **Sibling user namespace is the second cause** (matrix, label disabled
   on both): `--userns=keep-id --network container:<owner>` →
   `ioctl(TUNSETIFF): Operation not permitted` and nft
   `Error: Could not process rule: Operation not permitted` (M3 bridge owner,
   M4 pasta owner); `--userns container:<owner> --network container:<owner>`
   → `tun-ok`, `nft-ok` (M5, M6). With label NOT disabled, joining the
   owner's userns still fails at `open: Permission denied` (M5S), so both
   repairs are needed. Effective caps were `CapEff: 0000000000001000`
   (NET_ADMIN only) and the uid_map identical (`0 1 1000 / 1000 0 1 /
   1001 1001 64536`) in every arm: the difference is WHICH namespace, not
   which mapping.

7. **The packet's sysctl cannot be applied from a sibling userns.** F1:
   `arm:packet-sysctl-src-valid-mark rc=126` →
   `Error: crun: open /proc/sys/net/ipv4/conf/all/src_valid_mark: Permission
   denied: OCI permission denied`; so `arm:svc-netadmin rc=126` — the
   packet's exact launch line never starts. Repaired:
   `arm:repaired-sysctl-src-valid-mark rc=0`, value reads `1`.

8. **Repaired posture clears every pre-enrollment kernel arm**, on both an
   internal and a pasta owner (F2, F3, F4):
   `arm:repaired-tun-netadmin rc=0` → `probe0 DOWN 100.96.0.2/32`
   (a Mesh-range address assigns); `arm:repaired-nft-netadmin rc=0` →
   `table inet probe1506` (an output-hook filter chain installs, the
   mechanism the client's firewall uses); `arm:repaired-tun-no-netadmin
   rc=1` (`ioctl(TUNSETIFF): Operation not permitted` — NET_ADMIN is
   genuinely required, nothing is leaking it).

9. **The real router namespace has no route to Cloudflare.** The router
   launches only on `tillandsias-enclave`
   (`crates/tillandsias-headless/src/main.rs:6260-6261`,
   `ENCLAVE_NET` = `"tillandsias-enclave"` at :1921), and
   `podman network inspect tillandsias-enclave --format '... internal={{.Internal}}'`
   → `internal=true` (rc=0). A throwaway owner of that shape:
   `arm:edge-tcp-from-netns rc=1` → `connect: Network is unreachable` to
   `162.159.198.1:443`; daemon log `Failed to resolve API endpoint IP using
   DNS error=NoConnections host="api.cloudflareclient.com."` and `Failed to
   synchronize NTP time`. A pasta owner: `arm:edge-tcp-from-netns rc=0`, and
   the daemon's own unauthenticated pre-registration request
   `default_network_settings` completed `result=Ok` (127 ms in F2's daemon
   log, 204 ms in an earlier pasta run; a duplicate request in each logs
   `Err(Cancelled)`).
   So "the TUN appears in the router's namespace" (Decision 6) gives WARP no
   uplink: the sidecar's netns owner must have egress. Only TCP 443 was
   probed; MASQUE prefers UDP 443 (HTTP/3) with HTTP/2 fallback.

10. **Mode and protocol surface pre-registration.**
    `podman exec <svc> warp-cli --accept-tos settings` rc=0:
    `(default) Mode: Warp`, `WARP tunnel protocol: MASQUE`,
    `MASQUE (HTTP/3 with HTTP/2 fallback)`, default exclude split-tunnel
    includes `100.64.0.0/10` and `10.0.0.0/8` (the Mesh range and the
    enclave subnet are excluded by API defaults until a Zero Trust profile
    overrides them). `warp-cli mode --help` rc=0 lists `warp, doh,
    warp+doh, dot, warp+dot, proxy, tunnel_only`. Proxy mode exists in the
    client but Mesh needs Traffic and DNS mode (design note research §1), so
    proxy mode is not a fallback for Mesh.

Also measured (build hygiene, folded into `images/warp/Containerfile`):

- The vendor apt index lists ONLY the newest build:
  `curl -fsSL https://pkg.cloudflareclient.com/dists/{trixie,bookworm,noble}/main/binary-amd64/Packages | grep ^Version:`
  → one line each, `2026.7.1377.0` (rc=0 each). An `=version` apt pin
  breaks the build on the vendor's next release; the Containerfile installs
  the current build and REFUSES (`refused:warp-image:version-drift:...`)
  when it is not `WARP_VERSION`.
- The first probe build purged `curl gnupg` + `autoremove` after its version
  check; `cloudflare-warp` Depends on `gnupg2`, so the purge removed the
  client and the build still exited 0 (`dpkg-query: no packages found
  matching cloudflare-warp` inside the image). The cleanup was removed and
  `test -x /usr/bin/warp-svc` / `warp-cli` are now the build's last act.
- The script's first cleanup removed the netns owner before its sidecars;
  podman refused, and two pasta-run owners leaked (removed by exact name).
  The loop now runs in reverse creation order; a re-run (F4) left 0
  containers, 0 volumes, 0 networks matching `warp`.

## Runs

| run | command (all with `WARP_IMAGE=localhost/warp-probe-1506:2026.7.1377.0` unless --build) | rc | last line |
|---|---|---|---|
| F1 | `scripts/research-warp-sidecar-rootless.sh --throwaway --posture packet` | 0 | `outcome:tun-denied-rootless` |
| F2 | `WARP_IMAGE=localhost/tillandsias-warp-research:probe scripts/research-warp-sidecar-rootless.sh --throwaway --build --posture repaired --owner-network pasta` | 0 | `outcome-pending:enrollment-required:operator-minted-service-token-mdm.xml` |
| F3 | `scripts/research-warp-sidecar-rootless.sh --throwaway --posture repaired` | 0 | `outcome-pending:enrollment-required:operator-minted-service-token-mdm.xml` |
| F4 | `scripts/research-warp-sidecar-rootless.sh --throwaway --posture repaired --owner-network pasta` (cleanup re-check) | 0 | `outcome-pending:enrollment-required:operator-minted-service-token-mdm.xml` |

The script's rc is 0 whenever it reaches a verdict; the verdict is the last
line. The scratch matrix (M1–M7, M5S) was a one-off differential run outside
the tree; its arms are quoted in facts 5–6.

## What the operator must provide, and what enrollment will decide

To decide between `mesh-ip-acquired`, `registers-no-mesh-ip` and
`firewall-refused`:

1. A Zero Trust organization on the Free plan with Cloudflare Mesh enabled
   and a device profile in Traffic and DNS mode whose split-tunnel does NOT
   exclude `100.96.0.0/12` (the API default excludes all of `100.64.0.0/10`).
2. A service token (client id + secret) allowed to enroll devices, and the
   team name — written by the operator into an `mdm.xml`
   (`organization`, `auth_client_id`, `auth_client_secret`,
   `service_mode` warp, `warp_tunnel_protocol` masque, `auto_connect` 1,
   `onboarding` false) and passed as
   `scripts/research-warp-sidecar-rootless.sh --throwaway --posture repaired --owner-network pasta --mdm <file>`.
3. A decision on the two posture amendments (below), since the packet's
   posture cannot get past fact 4.

Enrollment-time questions this run cannot answer:

- Does registration via service token succeed from inside the container,
  and does a `100.96.0.0/12` address appear on the client's TUN?
- Does the client's connect-time firewall (nftables) install under the
  repaired posture, or does the community's "Failed to start firewall"
  shape appear? (The nft mechanism itself is permitted — fact 8.)
- Does connect need any capability beyond NET_ADMIN from the vendor unit's
  list (NET_RAW, NET_BIND_SERVICE, ...)?
- Does MASQUE get UDP 443 through pasta, or fall back to HTTP/2?
- Does the address survive a sidecar restart (the Cloudflare rung's
  criterion (a))?
- Does a service-token device consume a Free-plan seat?

## Consequences for 1506-t97c and Decision 6 (not decided here)

- `--userns=container:tillandsias-router` is refused by today's policy:
  `crates/tillandsias-podman/src/policy.rs:191` rejects any `--userns` value
  other than `keep-id`. The warp profile needs a named exception (joining a
  keep-id owner's namespace is the same mapping, not a weakening) or the
  join is impossible. `label=disable` is already admitted
  (`policy.rs:218-219`) and the router already uses it.
- The router netns is internal-only (fact 9). Either the WARP sidecar's
  netns owner gains egress (dual-home the router onto `tillandsias-egress`,
  which changes the router's exposure), or the sidecar owns its own
  egress-capable netns and the Mesh relay moves out of the router — an
  operator decision.
- `1506-t97c`'s exit-criterion argv (`--userns=keep-id`, no other flags)
  encodes the posture this run shows cannot work; it should name the output
  (a TUN and a Mesh address in the relay's namespace) rather than the flags.

## Cleanup

Created and removed by exact name/id: images
`localhost/warp-probe-1506:2026.7.1377.0` (two builds),
`localhost/tillandsias-warp-research:probe` (removed by the script's own
trap), and `docker.io/library/debian:bookworm-slim` (pulled by the first
build); containers `warp-research-<pid>-{owner,svc-a,svc-b}` and
`warp-matrix-1506-{owner,owner-pasta}`; networks
`warp-research-<pid>-internal`, `warp-matrix-1506-internal`; volumes
`warp-research-<pid>-state`. Final check:
`podman ps -a`, `podman volume ls`, `podman network ls` each show 0 names
matching `warp`; `podman images | grep -E 'warp|debian|<none>'` rc=1. No
`tillandsias-*` container, network or image was started, stopped or
attached to.
