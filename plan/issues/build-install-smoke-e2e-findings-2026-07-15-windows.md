# Windows local-build destructive e2e — findings 2026-07-15

discovered_by: /build-install-and-smoke-test-e2e (windows), driven by the
meta-orchestration cycle windows-bullo-fable5-20260715T0523Z.
Evidence: `target/build-install-smoke-e2e/20260715T060048Z/` (host-local).

## Run 20260715T060048Z — PASS on attempt 2 (attempt-1 failure was a real in-run finding, fixed forward)

- **Gate 1 build+install+freshness**: build-windows-tray.ps1 exit 0;
  direct-copy install to `%LOCALAPPDATA%\Programs\Tillandsias`; embedded
  SHA == HEAD both attempts (9cbe7849, then f32e84f9 after the in-run fix).
- **Gate 2 destroy**: `wsl --shutdown` + `--unregister tillandsias`, no
  distro listed after (run twice — once per attempt). Rootfs cache kept
  (warm-cache run; truly-cold path was proven 2026-07-13). Destructive
  reset per skill contract, `TILLANDSIAS_DESTRUCTIVE_RESET_OK` unset.
- **Gate 3 cold provision, attempt 1 — FAILED (finding, fixed in-run)**:
  the order-326 forge-user ensure (new this cycle, ea5b9e47) failed the
  provision loudly at "Configuring Fedora distro": `wsl` without `--exec`
  re-joins trailing args and re-parses them through the guest login shell,
  so the multi-line setup script arrived line-shredded (`$probe` expanded
  empty, `mkdir -p /home/forge/src` never ran; log:
  `03-provision.log` tail). The writability probe did EXACTLY its job —
  provision-time loud failure instead of a delayed clone EACCES. Fixed
  forward as f32e84f9: `wsl_root_sh_stdin()` delivers script bytes
  verbatim to the guest `/bin/sh`; delivery requirement unit-pinned.
  NOTE the hazard class: single-command/heredoc `wsl_root_sh` callers
  survive the re-parse today *by accident* — audit packet filed
  (provisional windows-260715-2).
- **Gate 3 cold provision, attempt 2 — PASS**: `RESULT: VM Ready — control
  wire up ✓`, handshake wire v2 attempt=1 (~80s configure→Ready). Tray log
  records `forge user + /home/forge/src ownership ensured (order 326)`.
- **Post-provision asserts (fresh substrate, no manual intervention)**:
  - `id forge` → uid=1000(forge); `/home/forge/src` → `forge:forge 755`;
    subuid/subgid `forge:524288:65536` (useradd auto-allocation) —
    **order 326 exit criterion 1 satisfied on a fresh provision**.
  - Elevated `--diagnose --json` exit 0: wire reachable, phase Ready,
    `elevated: true`, build_commit f32e84f9.
  - **Non-elevated** (runas /trustlevel:0x20000) `--diagnose --json`:
    `elevated: false`, wire reachable, phase Ready — **order 312's socat
    stdio bridge live on a pristine cold-provisioned substrate under a
    standard-user token**; privilege context recorded via the `elevated`
    field (312 exit criterion 3 evidence shape).
- **Gate 4 forge lane**: n/a (linux-only lane per skill).
- **Known warning (pre-existing, recorded 2026-07-13 too)**: `no embedded
  tillandsias-headless asset for this arch; guest will fetch the latest
  release` — guest binaries not staged before the tray build
  (scripts/build-guest-binaries.sh); version skew possible. Not a new
  finding; tracked by the order-282 staging flow.

## Residuals

- Order 326 exit criterion 2 (cold **cloud-attach clone** without manual
  chmod) still needs a lane-running/attended session — the ownership
  precondition it depends on is now proven above.
- 312/326 evidence lands durable in this file + plan events; raw logs are
  host-local under target/ (gitignored) per convention.
