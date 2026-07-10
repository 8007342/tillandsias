# macOS local-build e2e findings — 2026-07-09

- host: macOS arm64 (Tlatoanis-MacBook-Air), branch `osx-next`
- commit tested: `9cb47ff6` (osx-next = linux-next `2790d84c` + Darwin e2e-preflight fix)
- installed version: `tillandsias-tray 0.1.0 (git 9cb47ff6)`, VERSION `0.3.260709.4`
- discovered_by: /build-install-and-smoke-test-e2e (macos)
- evidence: `target/build-install-smoke-e2e/20260709T211045Z/` (local host, log
  excerpts inlined below since target/ is not committed)
- agent: macos-Tlatoanis-MacBook-Air-fable5-20260709T2105Z

## Gate results

| Gate | Result |
|---|---|
| 1 build + codesign + install + freshness (embedded git SHA == HEAD `9cb47ff6`) | PASS |
| 2 destroy substrate (2.0G VM dir + cache removed, verified absent) | PASS |
| 3 cold provision (528 MB rootfs download → convert → `{"status":"provisioned"}`, exit 0) | PASS |
| 3b `--diagnose --json` post-provision | PASS (exit 0, `provisioned: true`) |
| 4 forge lane | n/a (linux-only lane) |
| ext-A cold VM boot → phase Ready → vsock control wire connect | PASS |
| ext-B GitHub Login infra probe, cold first attempt | **FAIL** (vault name-in-use, below) |
| ext-C GitHub Login infra probe, second attempt | PASS to credential prompt |
| ext-D live tray launch: VmStatus/last_event propagation + clean SIGTERM | PASS |

The guest headless staged from the app bundle reports `Tillandsias
v0.3.260709.4` inside the VM — the bundled-guest staging path works, so
linux-next headless fixes are live in a locally built macOS VM without waiting
for a GitHub release (the release fetch is only the fallback).

## Verified: GitHub Login `ensure_git_login` fix (807a0950) live on macOS

The 2026-07-08 Linux bug (`tillandsias-git-login is a launch target, not a
satisfiable prerequisite`, `github-login-ensure-target-as-prerequisite-failure-2026-07-08.md`)
does NOT reproduce: `tillandsias-tray --github-login` on the cold VM proceeds
through the prerequisite chain (enclave/egress networks created, CA, vault
image build, proxy) and on the second attempt reaches the interactive
credential prompts (`matched: git author name`). Full credentialed login
remains attended-m8-smoke territory.

## FINDING 1 (bug, P1, linux pickup — promoted to plan/index.yaml order 259):
## cold-VM first `--github-login` fails: `tillandsias-vault` name already in use

First login attempt on the freshly provisioned VM:

```
[tillandsias-vault] bootstrap starting (Phase 6.5 hardened)
[tillandsias-vault] vault image missing — building on demand; ...
Pulling image vault [██████████] 100%
Error: creating container storage: the container name "tillandsias-vault" is
already in use by 365fc1c31db6...  ... or use --replace ...
Error: ensure tillandsias-git-login: tillandsias-vault not satisfied: podman run vault failed: exit status: 125
{"status":"login-finished","exit_code":1}
```

Post-mortem guest state: `tillandsias-vault Exited (143)` holding the name.
Two processes raced the vault bring-up inside one boot: the headless service's
own boot-path vault bootstrap and the login flow's `RealSatisfier` (the login
runs as a separate `tillandsias-headless --github-login` process via
control-wire exec, so in-process locks don't help). Order 232's advisory flock
(landed today, 2790d84c) did not prevent this — either the vault_bootstrap
path doesn't take the per-resource flock, or the loser of the race then fails
on plain `podman run --name` instead of adopting/replacing the existing
container. Same rm-on-reuse class as the fixed proxy P0
(`forge-launch-proxy-not-idempotent-2026-07-04.md`), now on vault. Retry
converges (attempt 2 reached the credential prompts), so impact is "first
login on a fresh VM always fails once" — a guaranteed bad first-run UX on
macOS and Windows VM hosts.

Repro: provision a fresh macOS VM, run `tillandsias-tray --github-login`,
observe exit 125 name-in-use on attempt 1 and success on attempt 2.

Smallest fix surface: vault check+act must hold the order-232 flock in BOTH
the boot bootstrap and satisfier paths, and the `podman run --name
tillandsias-vault` must handle an existing created/exited container
(start-or-replace) instead of erroring — the exact remedy order 235 (vault
recreate mutex, R7, ready) and order 233 (R5) already scope. Evidence from
this run should be attached to whichever packet lands it.

## FINDING 2 (fixed this cycle): e2e-preflight Darwin mis-verdict

`scripts/e2e-preflight.sh eligibility` returned `skip:no-podman-user-session`
on every macOS host because it required `/run/user/<uid>` on all platforms,
contradicting the meta-orchestration E2E table (macos local-build e2e: yes,
substrate = Virtualization.framework). Fixed in `9cb47ff6`: Darwin branch
probes `kern.hv_support` + smoke lock; explicit `XDG_RUNTIME_DIR` still
honored so the litmus pins stay deterministic; smoke-lock litmus step made
portable to flock-less hosts (macOS). `litmus:e2e-eligibility-probe-shape`
3/3 PASS on macOS after the fix.

## FINDING 3 (verified + ledger reconciled): event propagation to the tray

- Guest side: podman events → curated strings ("Securing Vault", "Building
  Forge", …) → `set_last_event` → `VmStatusPush` to subscribers +
  `VmStatusReply.last_event` (orders 152/153-slice1/230/231 all landed).
- Host side (live evidence, ext-D): installed tray booted the VM and logged
  `vm-status: phase=Ready podman_ready=true event=tillandsias-in-vm` — the
  guest's last_event crossed the control wire into the chip composer.
- Gaps: (a) the macOS tray has ZERO `Subscribe`/`*Push` consumers — the 30s
  poll in `action_host.rs` is the only propagation path, so events can lag up
  to 30s and intermediate events are lost between polls. Order 155
  (`macos-tray-stream-refactor`) returned from `pending` to `ready` this cycle
  now that orders 230/231 satisfied its dependency. (b) The observed
  last_event value was the initial placeholder (`tillandsias-in-vm`, the
  server name) — no container lifecycle action fired during the observation
  window, so the podman-events→chip mapping remains verified at unit level
  only; the next attended smoke or the order-155 implementation should catch a
  real "Securing Vault"-class event live.

## FINDING 4 (enhancement, macos, small): stale `--github-login` preflight workaround

`crates/tillandsias-macos-tray/src/diagnose.rs` github_login_main's guest
preflight still says "headless currently sets 0o600" and pre-creates
`/tmp/tillandsias-ca/intermediate.key` — but headless now sets 0o644
(`crates/tillandsias-headless/src/main.rs:1951,1995`). Half the workaround
(CA perms/openssl block) is likely removable; the `podman rm
tillandsias-proxy` half should stay until the shared rm-on-reuse fix (order
233/235 class) lands. Candidate small macOS cleanup after Finding 1's packet
closes.

## Flags for sibling hosts

- **linux**: (1) NEW order 259 (vault ensure race/rm-on-reuse, Finding 1;
  renumbered from 257 after a concurrent-append collision with linux's
  macos-tray-parity-column-verify) —
  blocks acceptable first-run GitHub Login on macOS/Windows; overlaps ready
  orders 233/235, consider landing them together. (2) Order 153 residual:
  all push topics done via 230/231; only SC-10 timed-lag criterion + 4-agent
  verification gate remain — please close so the tray refactor chain
  (144/154/155) is formally unblocked. (3) Order 254 (listen-vsock CI lane)
  protects the exact wire surface macOS consumes — currently 0 CI coverage.
- **windows**: order 154 (windows-tray stream refactor) dependencies are now
  genuinely satisfied (230/231 done) — same basis as order 155's un-blocking;
  the packet was already `ready`, this confirms it is actionable.
- **macos (this host, next cycle)**: order 155 is ready and claimable.

---

## Run 2 — 2026-07-09T23:18Z (meta-orchestration cycle, order 259 verification + order 155 slice 2)

- commits tested: `2a492797` (order 155 slice 2 on merged linux-next `67bffc86`),
  then `77b0ba92` (order 259 lock-namespace fix)
- evidence: `target/build-install-smoke-e2e/20260709T231816Z/` (local host)
- agent: macos-Tlatoanis-MacBook-Air-fable5-20260709T2310Z

### Gate results

| Gate | Result |
|---|---|
| 1 build + codesign + install + freshness (`2a492797`, then `77b0ba92`) | PASS ×2 |
| 2 destroy substrate (2.1G VM dir + cache, verified absent) | PASS ×2 |
| 3 cold provision (528 MB download → `{"status":"provisioned"}`, exit 0) | PASS ×2 |
| 3b `--diagnose --json` post-provision | PASS (exit 0, `provisioned: true`) |
| 4 forge lane | n/a (linux-only lane) |
| ext-A order 259 criterion 3, fresh VM first `--github-login` on `2a492797` | **FAIL** (exit 125 name-in-use — repro CONFIRMED on merged tree with linux structural slice) |
| ext-B same probe on `77b0ba92` after fix + full re-provision | **PASS** (reaches `matched: git author name` prompt; no 125, no podman error) |
| ext-C live tray: order 155 slice 2 push subscription | PASS (`push subscription established (vm-status/login/cloud polls demoted to fallback, SC-07)`, Ready chip via push, clean SIGTERM 143) |

### RESOLVED: FINDING 1 root cause (order 259) — disjoint lock namespaces

The linux structural slice (ensure_vault_running flock-before-check +
rm-before-run) is correct but was inert across the two guest processes:

- `tillandsias-headless.service` (vz.rs) set `HOME=/root` but no
  `XDG_RUNTIME_DIR` → `resource_lock::lock_dir()` fell back to
  `/tmp/tillandsias-locks-0`.
- The tray's `--github-login` exec preamble (diagnose.rs) exports
  `XDG_RUNTIME_DIR=/run/user/0` → satisfier locked under
  `/run/user/0/tillandsias-locks`.

flock(2) on different files never contends. Guest forensics after the failed
attempt: `tillandsias-vault` left in **Created** state (not Exited 143 as in
run 1 — the loser died at container-storage create, the winner never started
it before VM shutdown).

Fix `77b0ba92`: headless unit now pins `Environment=XDG_RUNTIME_DIR=/run/user/0`;
two source pin tests (vm-layer unit line, macos-tray preamble export) fail loud
if the values drift apart. Fresh-VM verification: ext-B PASS above.

**Windows heads-up (promoted to order 274; renumbered 260 -> 262 -> 265 -> 274 across three 2026-07-10 merge collisions)**: `wsl.rs` headless unit (~:350)
sets neither `HOME` nor `XDG_RUNTIME_DIR` — the WSL2 guest likely shares this
exact divergence.
