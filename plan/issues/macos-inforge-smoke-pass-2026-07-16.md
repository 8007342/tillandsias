# E2E REPORT: first in-forge /meta-orchestration smoke PASS on macOS — big-pickle inside OpenCode inside the VZ forge

- Date: 2026-07-16 (run 08:27→08:33Z)
- Class: e2e report (PASS) + goal burndown (operator goal: BigPickle/Hy3 in-forge /meta-orchestration)
- Filed by: macos-Tlatoanis-MacBook-Air-fable5-20260716T0824Z
- Launch: installed tray 0.3.260716.5 (git c40db47a), `--opencode /home/forge/src/tillandsias --prompt "Use the /meta-orchestration skill in smoke mode (verify-only)"`, one-shot, unattended
- Related: order 349 (macos-forge-config-trust-live-parity), plan/issues/macos-clone-lane-push-remote-misalignment-2026-07-16.md, order 382 (WSL2 sibling)

## Result

`MO-SMOKE: PASS` emitted as the final line; tray exit_code 0; lane cleaned
up ("no active lane containers; cleaning project + shared stack"). The
in-forge agent was **opencode/big-pickle** (Zen primary; config-default
routing pinned by litmus:zen-default-with-ollama-shape steps 1-2 inside the
same run). The agent honored smoke-mode rules: no claims, no commits, no
pushes, repo untouched.

In-forge checks it ran: host classification (TILLANDSIAS_HOST_KIND=forge
set), branch osx-next, plan/index.yaml parse OK, `git fetch --dry-run`
reachable, credential-channel guard, pre-build instant litmus sweep
(131 PASS / 10 FAIL / 132 SKIP), e2e-preflight (`skip:no-podman-binary`,
correct in-forge).

## Goal burndown (what remains for a FULL in-forge cycle on macOS)

1. **Operator `--github-login`** — vault `secret/data/github/token` still
   404 at 08:25Z (rechecked this cycle; vault healthy, 11 policies).
2. **Push route for the clone lane** — the in-forge guard live-confirmed
   plan/issues/macos-clone-lane-push-remote-misalignment-2026-07-16.md:
   `TILLANDSIAS_HOST_KIND=forge but origin does not resolve to the enclave
   git mirror (effective origin: /home/forge/src-host/tillandsias)`. The
   lib-common fix (559190c3) makes origin honest, but the lane still needs
   an actual mirror route before in-forge pushes can transit (linux seam).
3. **Image freshness** — the forge/git images are version-tagged
   (v0.3.260716.5) so the running lane does NOT pick up lib-common changes
   without an image rebuild; the smoke ran the PRE-fix entrypoint. This is
   the exact staleness class the FRESHNESS directive (orders 370-372)
   covers; no new packet filed for it.

## New findings from inside the lane (small)

- `.opencode/package-lock.json` shows MODIFIED in the ephemeral clone
  immediately after materialization — the forge lane itself dirties it, so
  every in-forge boundary snapshot starts dirty (noise; masks real dirt).
- Forge image tooling gap: `cmp` missing (1 litmus ENV-FAIL).
- 3 cheatsheet-sync litmus FAILs and 1 guest-binary-embed-integrity FAIL
  reproduced in-forge; the in-forge agent classified them as pre-existing/
  known (podman-sqlite cascade + sync debt already on the ledger).

## Verdict for the operator goal

The goal's smoke rung is DONE: a BigPickle agent inside OpenCode inside
the macOS forge ran a /meta-orchestration cycle end-to-end and reported
correctly. The full (push-capable) rung is blocked on items 1-2 above —
item 1 is the operator's single action; item 2 is linux-seam work already
filed and shaped.
