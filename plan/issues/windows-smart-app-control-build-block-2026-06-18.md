# Windows Smart App Control blocks native local-build e2e - 2026-06-18

Status: blocked (operator-attended)
Owner: windows host operator
Cycle: 2026-06-18T10:23Z windows meta-orchestration

## Summary

The native-Windows local-build e2e gate cannot run on this host. Smart App
Control (SAC) is enforcing and refuses to execute the freshly-compiled,
unsigned, no-reputation binaries that a Cargo build produces (build scripts,
proc-macro host artifacts, and the final binaries).

`cargo check -p tillandsias-policy` fails on the first build-script execution:

```
error: failed to run custom build command for `serde v1.0.228`
Caused by: could not execute process
  target\debug\build\serde-1504c37b86e8c767\build-script-build (never executed)
Caused by: Une stratégie de contrôle d'application a bloqué ce fichier. (os error 4551)
```

`os error 4551` is `ERROR_VIRTUS_FILE_BLOCKED_BY_POLICY` — an application
control policy blocked the file.

## Root cause

- `HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy\VerifiedAndReputablePolicyState = 1`
  → Smart App Control is in **enforce** mode.
- SAC blocks unsigned executables without established cloud reputation. Cargo
  build-script binaries and dev builds are unsigned and freshly generated, so
  every native build is blocked at the first build-script invocation.
- The prior Windows e2e PASS (`target/build-install-smoke-e2e/20260618T001325Z`,
  recorded in `build-install-smoke-e2e-findings-2026-06-18.md`) predates SAC
  entering enforce mode on this host.

## Impact

- Blocked: `./build.sh --ci-full --install` and any native `cargo build`/`check`
  on this Windows host.
- NOT blocked: the production Windows runtime substrate. The Tillandsias
  Windows runtime executes inside the `tillandsias` Fedora WSL2 VM (podman over
  vsock), which SAC does not gate. See the non-destructive probe below.

## Non-destructive substrate probe (this cycle)

- `wsl -l -v`: distro `tillandsias` present, `Stopped` (on-demand), VERSION 2.
- `wsl --status`: default distro `tillandsias`, default version 2.
- Conclusion: the production substrate is installed and healthy; the block is
  confined to the native dev/CI build path, not the runtime.

## Smallest next action (operator)

1. Decide SAC policy for this dev host. SAC enforce mode blocks all unsigned
   local builds; it can only be turned **off** via Settings → Privacy &
   security → Windows Security → App & browser control → Smart App Control →
   Off, and once off it cannot be re-enabled without an OS reset.
2. Alternatively, build inside the WSL2 distro (Linux toolchain, SAC does not
   apply) for native-Linux artifacts, and reserve native-Windows tray builds
   for a host where SAC is off.
3. After SAC is resolved, re-run the Windows local-build e2e
   (`/build-install-and-smoke-test-e2e`) to refresh the gate.

## E2E gate disposition this cycle

- Local-build e2e: BLOCKED by SAC (above). Not a code regression.
- Curl-install e2e: SKIPPED — latest GitHub release (`v0.3.260618.1`) equals the
  latest tested release recorded in the plan, so curl-install is not prioritized
  this cycle.
- Merged delta since last PASS is non-runtime on Windows: a Linux-only Rust
  policy checker (`tillandsias-policy check-cheatsheet-tiers`), plan docs, and
  the `repeat.ps1` launcher. `cargo fmt -p tillandsias-policy -- --check` PASS.
