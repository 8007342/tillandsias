# Enclave services do not survive a host reboot, and the nix-cache ensure path cannot manage the container it sits beside (2026-08-24)

- Date: 2026-08-24
- Class: enhancement (substrate resilience / preflight-remedy automation)
- Area: enclave service supervision / cycle-preflight / nix-cache-service
- Severity: medium (self-heals only by hand; every reboot silently degrades the enclave until a human or an agent notices)
- Owner: linux
- Discovered-by: yoga meta-orchestration cycle 2026-08-24T02:00Z (refusal cycle; filed from a clean clone)
- Status: ready

## Observed

yoga rebooted ~2026-08-23T23:44Z (uptime 2:14 at 2026-08-24T01:58Z). Afterward:

- `tillandsias-nix` and `tillandsias-builder` stayed `Exited (143)` — SIGTERM
  at shutdown, `restarts=0`, nothing supervising them back up.
  `scripts/cycle-preflight.sh` correctly flagged both
  (`fail:enclave-service-dead:...:origin=unlabelled`) but its overall verdict
  is `ok:cycle-preflight:...services-down2`, so an unattended cycle proceeds
  with a degraded enclave.
- The REST of the enclave came back without help (`tillandsias-vault`,
  `tillandsias-proxy`, `tillandsias-router` up ~2h; forge/inference containers
  up ~1h) — so supervision exists for some services and not others, and the
  difference is invisible in the preflight output.
- Manual remedy worked exactly as the preflight prose suggests: `podman start
  tillandsias-nix tillandsias-builder`; both up and stable minutes later.

## The mismatch

`scripts/nix-cache-service.sh ensure` — the sanctioned daily-maintenance path
for the nix cache service (order 801-kqme) — prints `skip:nix-cache:no-nix` on
yoga, because it gates on HOST nix. But the `tillandsias-nix` container exists,
runs, and is flagged by preflight when dead. On a no-host-nix machine the
ensure path can neither start nor health-check the very service the preflight
holds the cycle accountable for.

## Smallest next actions

1. Give enclave service containers a restart policy or systemd units
   (`podman generate systemd` / quadlets), so a reboot is not a silent
   degradation — the project's own idempotency principle applied to its
   substrate.
2. Either teach `nix-cache-service.sh ensure` to manage the containerized
   service when host nix is absent, or teach cycle-preflight not to demand a
   service the host's sanctioned ensure path refuses to own — one of the two
   is wrong on yoga today.
