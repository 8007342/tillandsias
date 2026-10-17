# E2E smoke — v56.10.16.1 — Windows (yolanda) — 2026-10-16

**Verdict: PASS**, with two qualifications that go first:
- `cosign:could-not-run:cosign-absent (winget install sigstore.cosign)`. The installer checks SHA256 only, against an unsigned manifest, so authenticity was NOT verified.
- **Not a credential clean room:** the operator's Credential Manager entries were kept (operator rule: never touch them). The `vault-*` entries the runbook's §2 deletes were left in place.

Channel daily, tag `v56.10.16.1` (pinned via `TILLANDSIAS_VERSION`), tray `56.10.16.1 (def043785)`.
Run start 2026-10-16T03:09:21Z. Sibling heads: main def043785, linux-next 9f00cdb08, windows-next b38f71052, osx-next 49731c152.
Evidence: `target/smoke-e2e/` on yolanda.

## Finding: no README ledger row for v56.10.16.1

`NO LEDGER ROW for v56.10.16.1` on linux-next 9f00cdb08. The newest row is v56.10.15.1. Per §0 step 2b, a missing row is a finding: the release's claims could not be read from the ledger. The claims tested here come from the coordinator's GO (#461 onboarding skill fix; #460/#466 Antigravity login rework).

## Steps

| Step | Result |
|---|---|
| §1 install | PASS. install_exit=0, tray at `%LOCALAPPDATA%\Programs\Tillandsias`, `--version` = 56.10.16.1 (def043785). |
| §1s signature | could-not-run: cosign absent. |
| §2 reset | `wsl --terminate`/`--unregister tillandsias` exit 0. Runtime caches purged by name. Builder vhdx snapshotted (228740562944 B). Credentials kept (see above). |
| §3 cold provision | PASS. `--provision-once` exit 0 in 83 s. Fresh distro newer than the destruction marker. Builder disk survived. `--status-once` Ready, podman_ready=true. `--diagnose` exit 0. |
| §4 lane | Tray running, lane as a `systemd-run` unit (the §4 Windows rule). |

## Arm 1 — 1743-h9rz: start-a-new-project is visible to OpenCode — PASS (fixed by #461)

Lane: `tillandsias-headless --cloud 8007342/tillandsias.org --opencode --prompt …`, lane_exit=0, 03:17Z to 03:21:54Z. Verbatim from the agent:
- `~/.config/opencode/skills` and `~/.claude/skills` now exist, each holding `project-discipline` and `start-a-new-project` symlinks to `/opt/skills/…`. On v56.10.15.1 both were missing.
- `~/.config/opencode/skill` (singular) is still absent, which is expected: opencode reads `skills`.
- opencode is 1.19.2.
- The agent's skill list includes `start-a-new-project`: `SKILL_PRESENT=yes`.

## Arm 2 — 1749-i47t: Antigravity lane — reaches the sign-in prompt (the 15.1 crash is not reproduced)

Lane: `timeout 120 tillandsias-headless --cloud 8007342/tillandsias.org --antigravity < /dev/null` as a systemd unit, with `podman events --format json` and a 1 s `podman inspect`/`podman logs` capture of the login container, so the `--rm` container could not take the evidence with it.
- The login flow printed every preparing step and `ready`.
- `tillandsias-antigravity-login-38279` (forge image v56.10.16.1): create, start and exec at 03:23:36Z.
- agy self-installed (1.3.6, checksum verified), then the TUI rendered "You are currently not signed in. Select login method: 1. Google OAuth / 2. Use a Google Cloud project".
- The container stayed `status=running exit=0` until my 120 s cap ended the lane (`lane_exit=124`). No exec_died event fired in the window.
- On v56.10.15.1 the same login exec died after 8 s.

**Reading:** the 8 s death is not reproduced on v56.10.16.1, consistent with #460/#466. NOT proven: completing a Google sign-in (that needs the operator) and the tray-menu path with a real pty. This lane had no pty, because `script` is absent from the guest. 1749-i47t should stay open until the operator finishes one sign-in from the tray.

Side observation: `[trust] WARNING: runtime proxy CA is not mounted; using vendor roots only` inside the login container.

## Memory (arm 3)

- Start: 9090 MB free of 15526 MB.
- **Lowest: 934 MB (6.0 %) at 03:16:50Z**, during arm 1's cold image builds. Sampled every 10 s.
- Nothing was reaped: the lane ran as a guest systemd unit.

## Known, not this cut's failure

- **1713-1dnx** is expected RED: the fix is #470, which is not in this cut. Not re-exercised.
- **Inference cold start:** the Antigravity lane logged `DEGRADED: local inference not ready … within 60s` (curl 7 to 11434), then continued. The lane's cleanup had just restarted the lane-scoped inference container. Logged as an observation; cold model re-pull is by construction on this lane (§2).

## Clean-up

No smoke containers or units remain. vault, proxy and inference are up (the tray holds the guest).
