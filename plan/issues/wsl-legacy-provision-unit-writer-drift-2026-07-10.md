# enhancement: two Windows headless-unit writers can drift apart (legacy provision vs recipe path)

- classification: enhancement (duplicate provisioning surface, drift risk)
- discovered_by: meta-orchestration (windows), order 274 implementation
- date: 2026-07-10
- scope: `crates/tillandsias-vm-layer/src/wsl.rs` `VmRuntime::provision` step 4
  vs `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs`
  `inject_bootstrap_logic` (the live w11 Fedora recipe path)

## Observation

Windows has TWO code paths that each write
`/etc/systemd/system/tillandsias-headless.service` from an independent string
literal:

1. the legacy tarball path (`WslRuntime::provision`, superseded by the
   2026-06 Fedora recipe pivot but still the `VmRuntime` trait impl), and
2. the live recipe path (`wsl_lifecycle.rs`), which carries hardening the
   legacy unit lacks (`NoNewPrivileges`, `CapabilityBoundingSet`,
   `ExecStartPre` preflight, vault env, `Restart=on-failure` semantics).

Order 274 demonstrated the failure mode: the order-259 lock-namespace fix
landed in the recipe unit + vz.rs but the legacy unit silently kept the old
shape — a distro provisioned through the trait path would reproduce the
vault name-in-use race (exit 125 on first login) that macOS already
root-caused and fixed. The 274 fix pins the lock-namespace fields in both
writers with source tests, but every OTHER field can still drift silently.

## Smallest closing slice

Decide the legacy path's fate (windows pickup, small):

- **Retire**: if nothing but tests exercises `WslRuntime::provision`'s unit
  install (the tray never calls it), replace step 4 with a deferral to the
  recipe path's unit or delete the tarball path outright with a
  `// DEPRECATED` cycle per methodology; or
- **Consolidate**: hoist a single unit-template constant (port-parameterized)
  shared by both writers, so one string literal feeds both and drift is
  structurally impossible; pin with one source test.

Either way, the pin tests added by order 274
(`wsl::tests::wsl_provision_unit_pins_lock_namespace_env`,
`wsl_headless_service_prepares_runtime_env`) stay as the fail-loud guard
until the consolidation lands.
