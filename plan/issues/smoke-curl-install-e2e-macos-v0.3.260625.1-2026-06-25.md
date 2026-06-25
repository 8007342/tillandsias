# macOS curl-install e2e -- released v0.3.260625.1 -- 2026-06-25

**discovered_by:** `/smoke-curl-install-and-test-e2e` on macOS
**Host:** Darwin arm64, end-user flow from a clean Tillandsias app substrate
**Release under test:** `v0.3.260625.1` (`origin/main` `3ee4c2ae`, published
2026-06-25T07:53:23Z)
**Agent:** `macos-codex-20260625T2111Z`

## Gates

| Gate | Result |
|---|---|
| `curl .../install-macos.sh | bash` downloads and extracts app | PASS with known verify bug |
| Installer SHA256 | PASS (`d4305e8c261e30e1ea48b2c0a72587480ee10e7615185918309d3d348cc798a6`) |
| Installer post-install verify | KNOWN FAIL: `DIAG_PIN...: unbound variable` (`plan/issues/install-macos-diag-pin-unbound-2026-06-22.md`) |
| Installed binary identity | PARTIAL: `--version` embeds `git 3ee4c2ae`, but still prints crate version `0.1.0` |
| Destructive macOS substrate reset | PASS: removed `~/Library/Application Support/tillandsias` and `~/Library/Caches/tillandsias` |
| Fresh `--provision` | PASS: Fedora Cloud image downloaded, converted, `rootfs.img` created |
| Static `--diagnose --json` | PASS: `rootfs_present=true`, `rootfs_bytes=5368709120`, `provisioned=true` |
| Tray boot readiness assertion | PASS: `phase=Ready podman_ready=true` at about 38s |
| `--exec-guest` control-wire probe | FAIL: stage 2 timeout waiting for vsock listener on port 42420 |
| `--github-login` dummy ordering probe | FAIL: host prompts for name/email/PAT before VM start, then same control-wire timeout |

## Remediation on osx-next

2026-06-25T22:07Z, agent
`macos-Tlatoanis-MacBook-Air-codex-20260625T213235Z`:

- Root cause: macOS cloud-init made `tillandsias-headless.service` require
  `tillandsias-headless-fetch.service`, while the fetch oneshot used
  `ConditionPathExists=!/usr/local/bin/tillandsias-headless`. Once the binary
  existed, later boots could skip the required oneshot and leave the vsock
  control-wire service absent.
- Fix: removed the condition and kept the fetch script idempotent; added
  `/usr/local/lib/tillandsias/headless-preflight.sh` to verify the headless
  binary and `/dev/vsock` while recording `podman.socket` and
  `/run/podman/podman.sock`; ordered/wanted `podman.socket` without making it a
  hard dependency for the diagnostic control wire.
- Credential ordering: macOS `github_login_main` now starts the VM, waits for
  control wire readiness, opens the vsock stream, and uses lazy expect
  responses so the host prompts only when the guest emits each prompt. Guest
  `run_github_login` now ensures the git image, networks, Vault, and login
  helper container before `prompt_and_store_git_identity()`.
- Local verification from signed `/Applications/Tillandsias.app` built from
  osx-next:
  - `target/smoke-e2e/local-01-provision.log`: fresh provision PASS.
  - `target/smoke-e2e/local-02-diagnose.json`: `provisioned=true`.
  - `target/smoke-e2e/local-03-exec-guest.log`: first boot exec printed
    `control-wire-ok`.
  - `target/smoke-e2e/local-04-exec-guest-second-boot.log`: second boot exec
    printed `control-wire-second-boot-ok`, proving the already-installed
    headless binary path.
  - `target/smoke-e2e/local-05-guest-systemd-health.log`: fetch, headless, and
    `podman.socket` all active; `/run/podman/podman.sock` present; preflight
    logged `headless_binary=ok`, `vsock_device=present`,
    `podman_socket=present`, `podman_socket_unit=active`.
  - `target/smoke-e2e/local-06-github-login-empty-stdin.log`: closed-stdin
    login probe logged VM start, control-wire readiness, and only then matched
    the guest author-name prompt; no vsock timeout.

Remaining architecture work: the full provider-neutral "required containers
UP+HEALTHY before credentials" contract still depends on the linux/shared
`podman-health-lifecycle-facade` packet. The macOS branch now consumes the
control-wire and guest-login ordering pieces, but Vault timeout increases remain
HACKY STOPGAPS until the shared Podman layer exposes first-class
`ping`/`keep_alive`/`restart`/`terminate`/`is_healthy`/`diagnose`.

## Headline

The clean curl-installed macOS release can install, provision, and reach the
normal tray `Ready` state, but the headless exec/login path regresses: both
`--exec-guest` and `--github-login` boot the VM to the Fedora login prompt and
then fail `VzRuntime::wait_ready` because the control-wire vsock listener never
appears.

`--github-login` also violates the credential-flow ordering requirement: the
host wrapper prompts for Git author name, Git author email, and PAT before it
starts the VM or proves that the guest/container stack is reachable. The guest
`run_github_login` path has a second ordering problem: it calls
`prompt_and_store_git_identity()` before ensuring the git image, enclave/egress
networks, Vault, and login helper container are up and healthy.

## Evidence

- `target/smoke-e2e/01-install-macos.log:1-21` -- release asset downloaded,
  checksum OK, app extracted, then known `DIAG_PIN...: unbound variable`.
- `target/smoke-e2e/03-provision-macos.log` -- clean provisioning reached
  `{"status":"provisioned","path":".../rootfs.img"}`.
- `target/smoke-e2e/03-diagnose-macos.json` -- static diagnose reports
  `rootfs_present=true`, `rootfs_bytes=5368709120`, `provisioned=true`.
- `target/smoke-e2e/03-enclave-readiness.log:10` -- normal tray boot reached
  `phase=Ready podman_ready=true at ~38s`.
- `target/smoke-e2e/04-exec-guest-probe.log:1-3` -- simple headless exec failed:
  `stage 2 timeout after 90s (vsock listener never came up at port 42420)`.
- `target/smoke-e2e/04-github-login-dummy.log:1-8` -- credential prompts appear
  before `[github-login] starting VM...`, then `wait_ready` fails with the same
  vsock listener timeout.
- `~/Library/Application Support/tillandsias/console.log:1-15` -- failed
  headless boots reach the Fedora login prompt; no control-wire readiness is
  visible before timeout.

## Operator Requirements Captured

`--github-login` and future auth flows (`Cloudflare`, `AWS`, `GoogleDrive`, and
similar) MUST rely on a shared runtime readiness contract instead of each flow
adding private sleeps, polls, or larger timeouts.

Before prompting for any user-provided credential or identity material, the
auth command MUST prove:

- the VM/control wire is reachable when running on macOS/Windows;
- the required Podman networks exist;
- all required containers for that auth flow are `UP`;
- all containers with healthchecks report `HEALTHY`;
- diagnostics are available when any required service is absent, exited, or
  unhealthy.

Recent timeout increases around Vault readiness (`60s -> 120s -> 180s`) are
therefore marked **HACKY STOPGAPS**. They are acceptable evidence-preserving
guards while debugging, but they are not the desired design. The durable fix is
an idiomatic Tillandsias Podman health/lifecycle layer with operations such as
`keep_alive`, `ping`, `restart`, `terminate`, `is_healthy`, and `diagnose`.

## Work Packet: smoke-finding/macos-exec-guest-control-wire-timeout

- id: `smoke-finding/macos-exec-guest-control-wire-timeout`
- owner_host: macos
- capability_tags: [macos, virtualization, control-wire, release, testing]
- status: done on osx-next; pending published release
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260625.1`
- evidence:
  - `target/smoke-e2e/04-exec-guest-probe.log:3` -- `wait_ready: stage 2 timeout after 90s (vsock listener never came up at port 42420)`
  - `~/Library/Application Support/tillandsias/console.log:8-15` -- second failed headless boot reaches Fedora login prompt only.
- repro:
  - `"/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray" --exec-guest /bin/bash -lc 'echo control-wire-ok'`
- next_action: >
    Compare the normal tray boot path that reaches `phase=Ready podman_ready=true`
    with the `--exec-guest`/`--github-login` main-thread path. Determine why the
    in-guest headless control-wire service is not started or not reachable in
    headless exec mode after a fresh curl install.
- events:
  - type: discovered
    ts: "2026-06-25T21:19:44Z"
    agent_id: "macos-codex-20260625T2111Z"
    host: macos
  - type: completed
    ts: "2026-06-25T22:07:50Z"
    agent_id: "macos-Tlatoanis-MacBook-Air-codex-20260625T213235Z"
    host: macos
    note: >
      Fixed in macOS VZ cloud-init/systemd ordering and verified with fresh
      local provision plus first-boot and second-boot `--exec-guest` success.

## Work Packet: github-login/readiness-before-credentials

- id: `github-login/readiness-before-credentials`
- owner_host: any
- capability_tags: [rust, macos, windows, linux, github-login, podman, vault]
- status: partial on osx-next; shared health facade pending
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260625.1`
- evidence:
  - `target/smoke-e2e/04-github-login-dummy.log:1-6` -- host prompts for Git author name, Git author email, and PAT before `[github-login] starting VM...`.
  - `crates/tillandsias-macos-tray/src/diagnose.rs:435-484` -- `github_login_main` prompts before `vz.start()` and `vz.wait_ready()`.
  - `crates/tillandsias-headless/src/main.rs:3939-3972` -- guest `run_github_login` calls `prompt_and_store_git_identity()` before image/network/Vault readiness.
- repro:
  - `printf 'Smoke Test\nsmoke@example.invalid\nghp_invalid_smoke_token\n' | "/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray" --github-login`
- next_action: >
    Move all host credential prompts behind a shared auth preflight that proves
    VM/control-wire reachability and required container stack health. Then move
    guest git identity prompting behind image, network, Vault, and login-helper
    readiness. The closure check must fail if any `--github-login` path can ask
    for credentials before the stack reports UP and HEALTHY.
- events:
  - type: discovered
    ts: "2026-06-25T21:19:44Z"
    agent_id: "macos-codex-20260625T2111Z"
    host: macos
  - type: progress
    ts: "2026-06-25T22:07:50Z"
    agent_id: "macos-Tlatoanis-MacBook-Air-codex-20260625T213235Z"
    host: macos
    note: >
      macOS host prompts now happen lazily after VM/control-wire readiness and
      guest prompts; guest git identity prompt moved behind image/network/Vault
      and helper-container startup. Remaining provider-neutral UP+HEALTHY
      preflight belongs to the shared Podman health facade.

## Work Packet: podman/health-lifecycle-facade

- id: `podman/health-lifecycle-facade`
- owner_host: linux
- capability_tags: [rust, podman, health, diagnostics, runtime]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260625.1`
- evidence:
  - `plan/issues/macos-github-login-vault-bootstrap-timeout-2026-06-22.md` -- Vault readiness has been stretched with successive timeout bumps.
  - `crates/tillandsias-podman-cli/src/lib.rs` -- only exposes `health wait`, not a full lifecycle facade.
  - `crates/tillandsias-podman/src/runtime.rs` -- runtime trait has start/stop/inspect/events, but no first-class `is_healthy`, `ping`, `restart`, `keep_alive`, or `diagnose` contract.
- repro:
  - Review `--github-login` and Vault bootstrap code paths; readiness is encoded as local loops/timeouts instead of a shared typed Podman health service.
- next_action: >
    Design and implement the idiomatic Tillandsias Podman health layer. It should
    consume Podman health/status/events where possible, expose typed lifecycle
    operations (`ping`, `keep_alive`, `restart`, `terminate`, `is_healthy`,
    `diagnose`), and give auth flows a single reusable preflight instead of
    private polling loops or bigger timeout constants.
- events:
  - type: discovered
    ts: "2026-06-25T21:19:44Z"
    agent_id: "macos-codex-20260625T2111Z"
    host: macos
