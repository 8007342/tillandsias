# Tasks: windows-wsl-runtime

## Phase 0 — prototype validation (DONE 2026-04-27)

- [x] Convert `tillandsias-forge:v0.1.170.249` (6.3 GB) to WSL distro
      via `podman export | wsl --import`. Verified Fedora 43 + agents.
- [x] `wsl --user forge --cd <winpath> --exec` reproduces
      `podman run --user 1000 -w` behaviour.
- [x] Confirm two WSL distros share one network namespace (same
      `eth0`/IP/MAC). Loopback inter-distro communication works.
- [x] Confirm `unshare`, `capsh`, cgroup-v2, tmpfs, bind mounts,
      `wsl.conf`, all reachable inside an imported distro.
- [x] Confirm Hyper-V firewall (`firewall=true`) is inbound-LAN only,
      not per-distro outbound — ruled out as forge-offline mechanism.

## Status snapshot (2026-04-27 10:20 — TRAY LAUNCHES CLEAN POST-INIT)

Final E2E loop verification on this Windows host:

1. `./build-local.sh` → debug binary at `%LOCALAPPDATA%\Tillandsias\tillandsias.exe`.
2. `tillandsias.exe --init` → imports all six WSL distros; reports
   `Ready. Run: tillandsias`.
3. `tillandsias.exe` (no args) → tray launches, hits `All images
   present at launch — skipping builds`, transitions through
   credential probe to `Mature` (Ready) state. Zero ERROR-level
   log lines. The image_exists patch on PodmanClient routes through
   `wsl --list --quiet` on Windows.

Additional cleanup landed in this loop:
- `rustls::crypto::ring::default_provider().install_default()` at
  the top of `main()` so Tauri-updater + reqwest TLS handshakes
  don't panic with "No provider set".
- `fetch_repos()` returns `Ok(Vec::new())` on Windows pending the
  Runtime trait migration (was generating noisy podman-pull errors
  trying to reach a docker.io image that doesn't exist).

## Status snapshot (2026-04-27 10:08 — E2E SMOKE PASSED)

`scripts/wsl-build/verify-smoke.sh` reports ALL SMOKE TESTS PASSED on
this Windows host:
- 6/6 WSL distros imported (`enclave-init`, `proxy`, `forge`, `git`,
  `inference`, `router`).
- Layer 1 forge-offline iptables egress drop is live in the shared
  WSL2 netns — verified by inspecting `iptables -L OUTPUT -v` from
  `tillandsias-proxy` and seeing the `TILLANDSIAS_FORGE_EGRESS`
  chain (uid 2000-2999 → loopback ACCEPT, others DROP).
- `tillandsias-forge` runs the `forge` user (uid 1000 image-baked;
  tray will pick a uid in 2000-2999 per attach).
- Tillandsias is podman-independent at the init level
  (`run_with_force_wsl` never calls `podman_cmd_sync`).

The forge tarball is 6.5 GB; build time on a fresh host is ~15 min
(after caches warm).

## Status snapshot (2026-04-27 09:45)

- [x] Phase 3: WSL-native build pipeline — `scripts/wsl-build/` with
      lib-common.sh, bases.sh, build-{enclave-init,proxy,git,inference,
      router,forge}.sh. Five smaller services build cleanly on a
      Windows host:
        - `tillandsias-enclave-init.tar` — 10 MB
        - `tillandsias-proxy.tar`        — 22 MB
        - `tillandsias-git.tar`          — 78 MB
        - `tillandsias-router.tar`       — 61 MB
        - `tillandsias-inference.tar`    — 184 MB
      Forge build is heavy (~5–7 GB tarball, ~15–25 min); validated by
      Phase A–H trace on this host.
- [x] Phase 5: `init.rs` Windows path migrated to WSL. Splits into
      `run_with_force_podman` (Linux/macOS) and `run_with_force_wsl`
      (Windows). The WSL path runs each `build-<service>.sh` via
      `bash.exe` (Git for Windows), then `wsl --import` into
      `%LOCALAPPDATA%\Tillandsias\WSL\<service>`. Embedded includes
      cover all eight wsl-build scripts.
- [x] Phase 6 Layer 1: `enclave-init` distro with uid-2000-2999
      iptables egress drop applied at WSL VM cold boot via
      `[boot] command` in its `wsl.conf`.
- [ ] Phase 6 Layer 2 (DEFERRED): forge entrypoint `unshare --net`
      + socat relay. Requires socat plumbing across netns; not on the
      smoke-test critical path.
- [ ] Phase 4: Runtime trait abstraction in `crates/tillandsias-podman`
      (deferred; would touch ~150 call sites). The tray's runtime path
      on Windows still uses podman APIs; a follow-up change is needed
      to migrate `handlers.rs`/`launch.rs`/`runner.rs` to a trait that
      dispatches to WslRuntime on Windows.
- [ ] Phase 7: E2E smoke test on this Windows host pending forge
      tarball completion (background build in progress).

## Phase 1 — runtime abstraction in Rust

- [ ] Define `Runtime` trait + `ServiceSpec` + `ServiceHandle` +
      `ExecSpec` in `crates/tillandsias-podman/src/runtime/mod.rs`.
- [ ] Move existing podman calls into `crates/tillandsias-podman/src/runtime/podman.rs`
      as `PodmanRuntime: Runtime`.
- [ ] Add `default_runtime()` constructor returning the right backend
      per `cfg(target_os = ...)`.
- [ ] Migrate consumers: replace direct `podman_cmd_sync()` /
      `podman_cmd()` calls with `Runtime` trait calls.
- [ ] Tests: a `MockRuntime` for unit tests; reuse existing podman
      tests against `PodmanRuntime`.

## Phase 2 — WslRuntime backend

- [ ] `crates/tillandsias-podman/src/runtime/wsl.rs` —
      `WslRuntime: Runtime`. wsl.exe driver, poll-based events.
- [ ] `service_create` clones the image distro (Phase 2A: full
      `wsl --export | wsl --import`; Phase 2B: copy-on-write VHDX).
- [ ] `service_start` is a no-op (a distro is "started" when an exec
      runs); `service_running` consults `wsl --list --running`.
- [ ] `service_exec` issues `wsl --distribution --user --cd --exec`.
- [ ] `service_stop` terminates the distro; `service_remove`
      unregisters it and removes the VHDX.
- [ ] `events_stream` poll-driven, 500 ms cadence, via
      `tokio::task::spawn_blocking` consuming `wsl --list --running`.
- [ ] Smoke integration test (`#[ignore]` by default; runs only on
      Windows hosts that have WSL2 installed).

## Phase 3 — WSL-native image build pipeline (no podman, anywhere)

- [ ] `scripts/wsl-build/lib-common.sh` — shared helpers:
      `wsl_import_temp <name> <tarball>`, `wsl_run_in <name> <cmd>`,
      `wsl_copy_into <name> <hostpath> <distropath>`,
      `wsl_export_and_unregister <name> <out_tar>`.
- [ ] `scripts/wsl-build/bases.sh` — base rootfs acquisition:
      Alpine via direct download from
      `dl-cdn.alpinelinux.org/alpine/v<x.y>/releases/x86_64/alpine-minirootfs-<x.y.z>-x86_64.tar.gz`
      (SHA-256 verified against Alpine's published checksums);
      Fedora via `skopeo copy docker://registry.fedoraproject.org/fedora:43 oci:./fedora-43`
      then layer-flatten. Cached under `~/.cache/tillandsias/wsl-bases/`.
- [ ] `scripts/wsl-build/build-proxy.sh` — Alpine + tinyproxy.
- [ ] `scripts/wsl-build/build-git.sh` — Alpine + git daemon.
- [ ] `scripts/wsl-build/build-inference.sh` — Alpine + ollama.
- [ ] `scripts/wsl-build/build-router.sh` — Alpine + caddy.
- [ ] `scripts/wsl-build/build-forge.sh` — Fedora + dnf install
      (mirrors `images/default/Containerfile`).
- [ ] `scripts/wsl-build/build-enclave-init.sh` — Alpine + iptables
      (the smallest distro; sets up forge-offline egress drops).
- [ ] `src-tauri/src/init.rs` Windows path: invoke each
      `build-<service>.sh`, then `wsl --import` the produced tarball.
      No `podman build`, no `podman export`.
- [ ] Tarball staging area: `target/wsl/tillandsias-<service>.tar`
      with sidecar `target/wsl/<service>.meta.json`
      (`default_uid`, `user`, `service_port`).
- [ ] Distro install location: `%LOCALAPPDATA%\Tillandsias\WSL\<service>`.
- [ ] Parity verifier: `scripts/wsl-build/verify-parity.sh`
      diffs the WSL-built tarball against a podman-built tarball
      under a Linux toolbox build, fails CI on divergence.

## Phase 4 — enclave-init distro + uid-based egress firewall

- [ ] New image `enclave-init` (Alpine ~22 MB) with iptables and a
      single startup script.
- [ ] Bake the iptables `OUTPUT` rules: drop forge uid range to non-loopback,
      allow loopback (per design D4 layer 1).
- [ ] Run `enclave-init` first at WSL VM cold boot (via
      `[boot] command` in `wsl.conf`); it sets the rules and exits.
- [ ] Rules validation in tray's pre-attach health probe (smoke
      curl tests per design D4).

## Phase 5 — forge-offline layer 2 (`unshare --net`)

- [ ] Modify `images/default/entrypoint-*.sh` (forge entrypoints)
      to `unshare --net` before exec'ing the agent. Add a
      `socat` relay so the agent's loopback can still reach the
      proxy's loopback.
- [ ] Verify on Linux that the same entrypoint works under
      podman without breaking today's path (the relay should be a
      no-op when the parent network namespace already has the proxy
      DNS alias).

## Phase 6 — service discovery

- [ ] `Runtime::service_address(service, port) -> SocketAddr` with
      backend-specific resolution.
- [ ] `tillandsias-services` CLI (forge-side) reads
      `TILLANDSIAS_RUNTIME_BACKEND=podman|wsl` env var (set by the
      tray) and emits the right address.
- [ ] Replace hardcoded `proxy:3128` / `git-service:9418` /
      `inference:11434` strings in the forge entrypoint scripts with
      `$(tillandsias-services proxy 3128)` etc.

## Phase 7 — resource limits via cgroup-v2

- [ ] First-launch helper: detect `~/.wslconfig` missing
      `kernelCommandLine=cgroup_no_v1=all systemd.unified_cgroup_hierarchy=1`,
      offer to write it, prompt `wsl --shutdown`.
- [ ] Forge entrypoint creates `tillandsias-attach.slice` cgroup
      with `memory.max` and `pids.max` from the profile.
- [ ] Validation smoke test: launch forge with `--memory=64m`,
      attempt to allocate 100 MB → must OOM-kill.

## Phase 8 — feature flag + cutover

- [ ] `TILLANDSIAS_RUNTIME=podman|wsl` env var (default `podman` on
      Linux/macOS, `wsl` on Windows once Phase 2 ships).
- [ ] `--runtime=wsl|podman` CLI flag for explicit selection.
- [ ] Documentation: `docs/strategy/wsl-only-feasibility.md` becomes
      historical reference; `cheatsheets/runtime/wsl-on-windows.md`
      becomes the operational doc.
- [ ] Update `CLAUDE.md` Windows Native Build section.

## Phase 9 — CI-built tarballs (acceleration only)

(Follow-up change: `windows-wsl-runtime-phase2`)

Podman never ships on Windows in this change, so there is nothing to
"retire". This phase is purely a build-time speedup — instead of
running `scripts/wsl-build/build-<service>.sh` on every user's host,
the tarballs are produced once in CI from a Linux toolbox and shipped
as GitHub release assets.

- [ ] CI workflow: build all five tarballs (`tillandsias-<service>.tar`)
      using `scripts/wsl-build/build-<service>.sh` under WSL on a
      Windows GitHub runner OR cross-equivalent on Linux.
- [ ] `--init` on Windows checks for a release-asset tarball matching
      `VERSION` first; falls back to local build only if missing
      (developer mode).
- [ ] `scripts/install.ps1` (when it lands) does NOT install podman
      or docker.
- [ ] Audit: confirm `Get-Process podman` returns nothing on a clean
      Windows install after `tillandsias --init`.

## Phase 10 — reopen control socket on Windows

(Follow-up change: `windows-wsl-control-socket`)

- [ ] Verify Win32 AF_UNIX `connect()` to `\\wsl$\<distro>\run\...\sock`.
- [ ] If yes: drop `cfg(unix)` gate in `control_socket/mod.rs`.
- [ ] If no: ship a tiny in-distro relay daemon, AF_UNIX → vsock or
      Named Pipe → relay → AF_UNIX inside.

## Smoke test acceptance criteria (end of Phase 8)

- [ ] `tillandsias --init` on a clean Windows host: builds + imports
      five WSL distros (proxy, forge, git, inference, router).
- [ ] `tillandsias` (no args) launches the tray; the tray's state
      machine reports proxy/forge/git/inference all "Ready" within 10 s.
- [ ] "Attach Here" on a project: forge distro clones, agent
      (claude or opencode) starts inside, agent's `curl https://example.com`
      fails with "Network unreachable" while
      `curl http://127.0.0.1:3128` succeeds.
- [ ] After detach: forge clone is `wsl --unregister`-ed, VHDX
      removed.
- [ ] No `podman.exe` process exists on the Windows host.

## Open / pending items

- [ ] OpenSpec delta specs for `cross-platform`, `podman-orchestration`,
      `enclave-network`, `forge-offline` — placeholders created;
      content TBD as the implementation lands.
- [ ] Cheatsheet `cheatsheets/runtime/wsl-on-windows.md` — operational
      runbook for users running Tillandsias on Windows after this
      ships.
- [ ] Decision: keep `tillandsias-podman` crate name or rename to
      `tillandsias-runtime`. Lean toward the rename in Phase 9 to
      reduce confusion.
