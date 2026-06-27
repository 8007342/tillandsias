# macOS curl-install e2e — released v0.3.260626.5 — 2026-06-26 (session 2)

**discovered_by:** `/smoke-curl-install-and-test-e2e` on macOS
**Host:** Darwin arm64, Tillandsias.app installed from release
**Release under test:** `v0.3.260626.5` (published 2026-06-26T21:36:52Z)
**Agent:** `macos-smoke-20260626T1500Z`

## Gates

| Gate | Result |
|---|---|
| Release v0.3.260626.5 assets published (headless aarch64 musl) | PASS |
| `--github-login` control wire + Vault bootstrap start | PASS |
| Vault container pull | PASS — image pulled to completion |
| Vault API probe | **FAIL** — TLS cert `NotValidForName` for `10.0.42.2` |
| `--github-login` exit code | FAIL — `exit_code:1` |

## Error

```
Error: vault podman health is healthy but API probe failed: vault network error:
error sending request for url
(https://10.0.42.2:8200/v1/sys/health?sealedcode=200&uninitcode=200&standbyok=true):
error trying to connect: invalid peer certificate: NotValidForName
{"status":"login-finished","exit_code":1}
```

## Root Cause

The vault TLS certificate is issued for the DNS hostname `vault`, not for the
IP `10.0.42.2`. In v0.3.260626.5:

- `crates/tillandsias-vm-layer/src/vz.rs`: headless systemd service embeds
  `Environment=TILLANDSIAS_VAULT_API_BASE_URL=https://10.0.42.2:8200`
- `crates/tillandsias-macos-tray/src/diagnose.rs:github_login_main`: exec
  command injects `TILLANDSIAS_VAULT_API_BASE_URL=https://10.0.42.2:8200`
- The vault's TLS cert SAN contains `vault` (the Podman service DNS name), not
  `10.0.42.2`

Both must use `https://vault:8200` to match the cert.

## Resolution

**Already fixed on linux-next** (commit `f948defa feat(headless): route vault
by service DNS`):

- `vz.rs`: `Environment=TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200`
- `diagnose.rs`: `export TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200`

Both changes were merged to osx-next via ff-pull on 2026-06-27 and included
in the local macOS tray build.

## Additional Context: exec-guest PTY output not captured in background mode

Discovered during headless binary update attempt: the macOS tray's
`--exec-guest` bridges PTY output to the raw terminal (not to stdout/stderr),
so background Bash invocations cannot capture guest output lines. Only the
`[exec-guest]` prefix lines from the tray process itself appear. Interactive
use (`!` prefix in Claude Code) is required for any exec-guest command that
needs visible output.

## Work Packet: smoke-finding/vault-cert-ip-not-valid-for-name

- id: `smoke-finding/vault-cert-ip-not-valid-for-name`
- owner_host: any
- capability_tags: [rust, vault, macos, tls, networking]
- status: done
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260626.5`
- evidence:
  - `--github-login` output: `invalid peer certificate: NotValidForName` when
    probing `https://10.0.42.2:8200`
  - `crates/tillandsias-vm-layer/src/vz.rs` — `TILLANDSIAS_VAULT_API_BASE_URL=https://10.0.42.2:8200`
  - `crates/tillandsias-macos-tray/src/diagnose.rs` — same IP in exec command
- next_action: Already fixed. Use `https://vault:8200` (DNS name matching cert SAN).
- events:
  - type: discovered
    ts: "2026-06-26T22:05:00Z"
    agent_id: "macos-smoke-20260626T1500Z"
    host: macos
  - type: completed
    ts: "2026-06-27T00:00:00Z"
    agent_id: "macos-advance-20260627T0000Z"
    host: macos
    note: >
      Fixed on linux-next (f948defa). Fast-forwarded into osx-next
      on 2026-06-27 ff-pull. Local macOS tray build now uses vault DNS name.

## Work Packet: smoke-finding/exec-guest-pty-output-not-captured-in-background

- id: `smoke-finding/exec-guest-pty-output-not-captured-in-background`
- owner_host: macos
- capability_tags: [rust, macos, ux, diagnose]
- status: ready
- discovered_by: macOS operator session 2026-06-26
- evidence:
  - Multiple exec-guest background task outputs show only 3 lines:
    `[exec-guest] starting VM…`, `[exec-guest] waiting for control wire…`,
    `[exec-guest] running: [...]` — guest PTY output never appears.
  - Workaround: `! tillandsias-tray --exec-guest "cmd"` in interactive terminal.
- repro:
  - Run `tillandsias-tray --exec-guest "echo hello"` as a non-interactive
    subprocess; observe no guest output in captured stdout.
- next_action: >
    In `exec_guest_main` (crates/tillandsias-macos-tray/src/diagnose.rs),
    collect the PTY output into a buffer and print it to stdout after the
    command completes, rather than bridging the raw PTY to the terminal.
    The `ExecOutput { exit, stdout }` from `exec_over_stream_with_input`
    already accumulates output — ensure it is written to stdout (not /dev/tty)
    before the function returns.
- events:
  - type: discovered
    ts: "2026-06-26T22:30:00Z"
    agent_id: "macos-smoke-20260626T1500Z"
    host: macos
