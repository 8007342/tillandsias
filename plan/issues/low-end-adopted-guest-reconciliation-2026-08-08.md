# low-end-adopted-guest-reconciliation — adopt-path guest wiring never reconciles across tray upgrades

Filed 2026-08-08 from the Intel N100 field host (`Esmeralda`, Windows 11 Pro
26200, 16GB RAM, WSL 2.7.10). Deliverable for the packet of the same id.

trace: spec:vm-provisioning-lifecycle, plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md (adopt doctrine this amends)

## Bootstrap receipt (methodology/bootstrap/router.yaml)

- selected_intent: bug_fix
- active_roles: windows field host, worker
- files_read: methodology.yaml, methodology/bootstrap/router.yaml, plan.yaml,
  plan/index.yaml (head), plan/loop_status.md, methodology/multi-host-development.yaml,
  methodology/ci.yaml, plan/steps/README.md, plan/index.d/README.md (via analysis
  agents), crates/tillandsias-windows-tray/src/wsl_lifecycle.rs,
  crates/tillandsias-vm-layer/src/transport_windows.rs,
  crates/tillandsias-headless/src/{main.rs,vsock_server.rs},
  crates/tillandsias-host-shell/src/vsock_client.rs,
  scripts/{build-windows-tray.ps1,build-guest-binaries.sh,with-wsl2-builder.sh,install-windows.ps1}
- governing_specs_or_traces: spec:vm-provisioning-lifecycle, spec:windows-native-tray,
  order 282 (version skew), order 312 (non-elevated transport), order 418
  (registered-distro integrity probe), order 443 (inference reuse)
- missing_or_conflicting_references: `.import-complete` records the writing
  tray's WORKSPACE_VERSION but nothing reads it (wsl_lifecycle.rs) — noted as a
  future gate in the 2026-08-08 deep-dive; this packet implements the runtime
  equivalent (query the guest binary itself, which cannot go stale).
- intended_change_scope: crates/tillandsias-windows-tray/src/wsl_lifecycle.rs
  (UseRegistered arm + two new methods + parse helper + tests)
- verification_plan: workspace unit tests; live e2e on this host — release tray
  reproduces the failure, locally built tray with the fix reconciles the adopted
  guest and reaches wire Ready (`--diagnose --json` exit 0, non-null guest_version)
- host_id: windows-esmeralda
- platform: windows
- observed_sibling_heads: main 7491caf2, linux-next 63784ddb,
  windows-next 936c1899 (ancestor of linux-next, 0 unique), osx-next 936c1899

## Field failure (evidence)

Release v0.4.260804.1 portable tray, run from Downloads, non-elevated. The
`tillandsias` WSL distro imports and starts, then every connect attempt fails
`handshake: early eof` until "control-wire handshake did not succeed within
budget" (tray.log cycles on 2026-07-23, -07-28, -08-05, -08-08; diagnose bundle:
`wire.reachable=false`, `guest_version=null`, `elevated=false`, exit 2).

Three stacked guest-side causes, all traced to ONE product defect:

1. **Stale guest binary**: `/usr/local/bin/tillandsias-headless` in the guest is
   v0.3.260712.1 (fetched 2026-07-23 by a July local build whose fetch script
   used `releases/latest`). The v0.4.260804.1 tray handshake dies against it.
2. **No `vsock_loopback`**: the July-era distro predates the modules-load
   injection (wsl_lifecycle.rs `/etc/modules-load.d/tillandsias-vsock.conf`).
   Verified live: `socat VSOCK-CONNECT:1:42420` → `Network is unreachable`
   with the listener provably up; after a manual `modprobe vsock_loopback` the
   connect succeeds. Non-elevated trays (the socat stdio bridge) can therefore
   NEVER connect on such guests; the failure surfaces as bare `early eof`
   because socat outlives the 250ms BRIDGE_STARTUP_GRACE on N100-class wsl.exe
   launch latency (see packet low-end-bridge-eof-diagnosability).
3. **Retired unit hardening still live**: the guest's headless unit still has
   `NoNewPrivileges=yes` + `CapabilityBoundingSet=CAP_NET_BIND_SERVICE`, which
   current injection deliberately dropped (rootful podman selects rootless mode;
   verified live: `cannot write uid_map ... operation not permitted` loops,
   vault ensure fails with `Failed to create runtime asset parent: Permission
   denied`).

**Root defect**: the registered-distro fast path (order 418) ADOPTS any distro
whose `wsl --exec /bin/true` probe is green and never re-injects wiring, so a
guest provisioned by tray version X keeps X's binary/units/modules forever
under tray version Y. The exec probe answers "can it exec", not "does its
Tillandsias wiring match this tray".

## Fix (implemented this session on windows-next)

`crates/tillandsias-windows-tray/src/wsl_lifecycle.rs`:

- `adopted_guest_headless_version()` — `wsl -d tillandsias -u root --
  /usr/local/bin/tillandsias-headless --version`, 30s cap, parsed by the pure
  `parse_headless_version()` (unit-tested); `None` = absent/failed.
- `reconcile_adopted_guest()` — called from the `UseRegistered` arm after
  `runtime.start()`: when guest version != `WORKSPACE_VERSION` (or `None`),
  run `ensure_base_packages()` (rpm-q gated, idempotent), stop the stale
  units (avoids ETXTBSY on the running ELF), re-run the idempotent
  `inject_bootstrap_logic()` (embedded source-matched binary or version-pinned
  fetch script, current unit definitions, vsock_loopback modules-load), then
  restart fetch+headless. Version-equal guests skip everything, keeping the
  fast path fast. Reconciliation failure warns and continues (non-destructive,
  probe-green-is-truth doctrine preserved).

## Exit criteria

- [x] Locally built tray on this host adopts a stale guest, reconciles, and
      reaches wire Ready — VERIFIED 2026-08-09T00:37Z, see evidence below.
- [x] Workspace unit tests green (`parse_headless_version` truth table).
- [ ] Follow-up (ready): a litmus that provisions a version-skewed guest fixture
      and asserts reconciliation restores the wire without `wsl --unregister`.

## E2E evidence (2026-08-09, Esmeralda)

The test exercised the HARDEST reconcile case: a fresh import whose provision
had been interrupted mid-`ensure_base_packages` (binary absent, units absent,
no wsl.conf systemd flip). Non-elevated launch (socat bridge path):

    00:34:40 INFO adopted guest wiring is stale — re-injecting bootstrap logic
             guest_version="<absent>" tray_version=0.4.260804.1
    00:34:44 INFO adopted guest is not systemd-booted — completing the
             configure step before injection
    00:35:32 INFO Injecting embedded tillandsias-headless binary arch=x86_64
    00:37:04 INFO VM handshake success (phase=Ready) wire_version=2 attempt=1
    00:37:04 INFO VM ready — control wire established

`--diagnose --json` after: exit 0; version=0.4.260804.1 commit=63784ddb;
guest_version=0.4.260804.1 (was null under the release install);
wire.reachable=true phase=Ready podman_ready=true last_event="Securing Vault".
The handshake succeeded on ATTEMPT 1 over the non-elevated bridge — proving
the injected vsock_loopback modules-load entry works (WSL had rebooted since
the diagnostic-phase manual modprobe, so the durable path is what ran).

Session amendments folded into this packet's scope:
- ensure_base_packages timeout 300s → 1500s (dnf verified mid-transaction
  with healthy DNS when the old ceiling fired on this host).
- Reconcile completes configure_recipe_distro for adopted guests that are not
  systemd-booted (interrupted-provision adoption).

## Evidence / handoff

- Branch: code on windows-next (merged origin/linux-next 63784ddb first);
  this note + index.d fragment on linux-next.
- Owned files: crates/tillandsias-windows-tray/src/wsl_lifecycle.rs.
- Residual risk: a stale guest whose version string EQUALS the tray's (same
  VERSION, different code — local dev iterating without a bump) is not
  reconciled; the version string is the contract. Acceptable: CI/release
  builds always bump.
- Next action: run the e2e verify on this host and append the diagnose JSON
  excerpt here; then mark the packet completed via a new index.d fragment.
