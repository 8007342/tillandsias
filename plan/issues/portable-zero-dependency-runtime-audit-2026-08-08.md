# portable-zero-dependency-runtime-audit — keep the "zero dependencies, ephemeral, portable" promise measurable

Filed 2026-08-08 from the Intel N100 field host (`Esmeralda`). Deliverable for
the packet of the same id (order 620-duta). Operator directive: the product
promise is a "zero dependencies ephemeral portable tool" — runtime dependencies
must be tracked carefully and separated from dev-time dependencies, and the
separation must be DETECTABLE at runtime, not asserted in prose.

trace: spec:linux-native-portable-executable, spec:windows-native-tray,
spec:vm-provisioning-lifecycle

## Dependency inventory as of this session (Windows host)

**Runtime (end-user machine) — unchanged by this session's fixes:**

- `tillandsias-tray.exe`: single portable binary. Links only OS-shipped
  Windows libraries (kernel32/ntdll/ws2_32/dbghelp/ucrt); no VC redist, no
  installer prerequisite. The guest headless binary is EMBEDDED per-arch
  (static musl ELF), so a fresh provision needs no release download.
- WSL2 platform (`wsl.exe`): the one host-level runtime dependency; already a
  first-class provisioning precondition (order 323 classifier; the tray can
  drive `wsl --install --no-distribution` itself).
- In-guest packages (systemd, podman, socat, dbus-broker, …): self-provisioned
  by the tray INTO the ephemeral `tillandsias` distro via dnf at first
  provision/reconcile (`ensure_base_packages`). Network is required for that
  first provision; everything lands inside the disposable distro, never on the
  host. `wsl --unregister tillandsias` (or installer -Purge) removes all of it
  — the ephemerality contract.
- `vsock_loopback` kernel module (WSL2 kernel ships it): loaded via the
  injected `/etc/modules-load.d/tillandsias-vsock.conf`. Required ONLY by the
  non-elevated socat bridge path.

**Dev-time only (build hosts; never consulted by the shipped binary):**

- Windows: rustup + cargo + MSVC Build Tools + Windows SDK (installed on this
  host 2026-08-08 purely to build; the installed tray was verified to run
  before any of them existed — the release binary ran and failed for guest-
  state reasons, not missing host libraries).
- WSL: the dedicated `tillandsias-build` distro (with-wsl2-builder.sh) with
  gcc/musl-gcc/cmake/etc. Deliberately separate from the runtime distro so
  destructive smoke can never wipe toolchains, and vice versa the product
  never touches the build distro. musl-gcc/musl-devel/musl-libc-static were
  missing from the builder init and are now added (ring's build script
  hard-requires x86_64-linux-musl-gcc for the musl guest).

**This session added ZERO new runtime dependencies.** The three fixes
(adopted-guest reconciliation, inference gate, bridge EOF attribution) reuse
existing product mechanisms (wsl exec, dnf ensure, systemd injection).

## Why the downloaded release binary failed here (for the record)

The v0.4.260804.1 zip was CORRECT — the release pipeline hard-gates on the
embedded source-matched guest binary. It failed on this host because the
existing `tillandsias` distro carried July-era wiring (stale v0.3.260712.1
guest binary, retired hardened unit, no vsock_loopback) and the adopt fast
path never reconciles adopted guests. Portable-binary correctness cannot fix
stale ephemeral-substrate state unless the binary VERIFIES that state at
runtime — which the reconciliation fix now does on every adopt.

## Exit criteria (runtime detectability)

- [ ] `--diagnose --json` reports the guest wiring version and the last
      reconcile outcome (adopted-in-sync | reconciled | reconcile-failed), so
      "stale adopted guest" is an observable state, not an inference from
      handshake failures.
- [ ] `headless-preflight.sh` asserts `vsock_loopback` is loaded (warn line at
      minimum) so the non-elevated bridge's kernel prerequisite is visible in
      the guest journal.
- [ ] A litmus asserting the installed tray binary imports/links nothing
      outside the OS-shipped set (e.g. dumpbin /dependents allowlist), pinning
      the zero-runtime-deps promise falsifiably.
- [ ] Docs: dependency inventory above distilled into the owning spec(s), with
      this file left as a tombstone pointer.

## Evidence / handoff

- Branch: this note + fragment on linux-next; no code owned by this packet yet
  (the three exit-criteria items are unclaimed follow-up work).
- Related: low-end-adopted-guest-reconciliation (the runtime verifier),
  low-end-no-local-inference-gate (footprint), scripts/with-wsl2-builder.sh
  (dev-only builder init, musl-gcc gap closed 2026-08-08).
