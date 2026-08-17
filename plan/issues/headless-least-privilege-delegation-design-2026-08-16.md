# Headless least-privilege: podman API-socket delegation (design record, order 309)

- **Status:** decided · **Decided by:** linux-yoga-claude-20260816t185912z (yoga
  meta-orchestration cycle, 2026-08-16) · **Class:** order 308 follow-up
- **Packet:** `headless-least-privilege-split` (order 309, socket-audit-master)

## Decision

Reintroduce least-privilege on the guest headless unit via **podman API-socket
delegation**, not the confined-listener/unconfined-orchestrator process split.

The 308 wedge was never "hardening is impossible": `NoNewPrivileges=yes` +
`CapabilityBoundingSet=` on a uid-0 headless that OWNS the podman store makes
podman select rootless mode (empty store; pause-process fatals under NNP), so
every vault/lane ensure exited 125 in a 2s loop and the tray latched on
"securing vault" (forensics:
`plan/issues/headless-podman-events-watcher-rootless-wedge-2026-07-12.md`).
Delegation removes the store from the confined process entirely: the headless
becomes a podman **client** over the socket-activated rootful `podman.service`,
which keeps the privileges.

## Why delegation beats the process split

- The remote transport already ships: `tillandsias-podman` honors
  `TILLANDSIAS_PODMAN_REMOTE_URL` → `podman --remote --url unix://…`
  (`crates/tillandsias-podman/src/lib.rs:405-501`), including the
  service-account-lane guard that REQUIRES the env (`lib.rs:254`).
- The guest unit already `Wants=`/`After=` `podman.socket`.
- The split needs a new binary plus a local IPC surface through a 22k-line
  `main.rs` whose listener is owned by `vsock_server.rs` — invasive, and every
  privileged operation would still need a delegation protocol of its own.

## Target directive set (the windows-side edit)

For the WSL guest headless unit template (`crates/tillandsias-windows-tray/src/wsl_lifecycle.rs`):

```ini
NoNewPrivileges=yes
CapabilityBoundingSet=
Environment=TILLANDSIAS_PODMAN_REMOTE_URL=unix:///run/podman/podman.sock
```

- The vsock listener binds port 42420 — no `CAP_NET_BIND_SERVICE` needed.
- The empty-set tilde-form gotcha from the 308 forensics applies: an EMPTY
  `CapabilityBoundingSet=` is the intent (drop everything), not the `~` form.
- The three lines are a UNIT: hardening directives may ship ONLY together with
  the delegation env (pinned by
  `litmus:headless-least-privilege-delegation-shape`).

## Audit: the headless podman surface is delegation-ready (2026-08-16, linux)

- Every production podman spawn routes through the shared layer
  (`podman_cmd`/`podman_cmd_sync`/`PodmanClient`); the source pin
  `idiomatic_podman_launch_paths_do_not_bypass_shared_layer`
  (`crates/tillandsias-headless/src/main.rs`) enforces no direct
  `Command::new("podman")` in launch paths, so `--remote` injection via the
  env reaches everything.
- `pty_handler.rs:~190`'s `podman exec -it` is an argv ALLOWLIST matcher
  (validation), not a spawner — the spawn still flows through the wrapper.
- Live probe on yoga (podman 5.8.4, user socket): under a transient unit with
  `NoNewPrivileges=yes` and `CONTAINER_HOST=unix://$XDG_RUNTIME_DIR/podman/podman.sock`,
  `podman info` and `podman ps` succeed as a pure client — exactly the shape
  that ships post-delegation, and the shape the 308 class would have broken.
  (User managers cannot apply `CapabilityBoundingSet=` — systemd 218/CAPABILITIES —
  so the dev-host litmus pins the NNP half; the system manager applies the
  full set in production.)

## Cross-host handoff

- **windows-next:** edit the unit template in `wsl_lifecycle.rs` (the region
  whose comment currently says "No NoNewPrivileges / CapabilityBoundingSet
  here", ~line 1668) to the directive set above, and FLIP the pin tests at
  ~2712-2719 from asserting absence to asserting the three-line unit ships
  together. Verify live on the next attended windows smoke: no "securing
  vault" latch, vault/lane ensures exit 0.
- **macOS (follow-on):** criterion 2 was already discharged — the 2026-08-16
  macos progress event confirmed `vz.rs`/`wsl.rs` guest units carry zero
  hardening-family directives today; hardening the vz unit follows once
  delegation is proven on WSL.

## Verifiable checks

- `litmus:headless-least-privilege-delegation-shape` (pre-build, instant):
  joint-invariant grep on the unit template (hardening ⇒ delegation env, with
  a fixture negative control) + the live delegated-client probe under
  `NoNewPrivileges=yes`.
- Existing: `idiomatic_podman_launch_paths_do_not_bypass_shared_layer`,
  `wsl_headless_service_prepares_runtime_env` (flips with the windows edit).
