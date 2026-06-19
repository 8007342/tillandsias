# GitHub login fails from CLI and tray — regression — 2026-06-18

Reported by: The Tlatoani (direct, 2026-06-18)

## Summary

GitHub login fails both from the command line and from the tray UX. Operator
report (verbatim):

> "github login from command line, and from the tray UX, both fail with an
> error. I have not been able to login into github in the last several builds,
> but this is something that was working before."

This is a regression — GitHub login worked in earlier builds and has been broken
"in the last several builds." Logging into GitHub is core auth: without it the
GitHub token never lands in Vault, so cloud-project discovery, clone, and the
forge/git-mirror credential path are all downstream-blocked.

## Regression context (important)

There is a very recent, closely related packet that was marked **done** but was
never validated against a live login:

- `plan/issues/github-login-enclave-egress-regression-2026-06-17.md`
- Fix commit `d3f4e2f3` "fix(headless): dual-home github-login helper to managed
  egress network" — changed the gh-login helper container from single-homed
  `ENCLAVE_NET` (`tillandsias-enclave`, `--internal`, no egress) to dual-homed
  `ENCLAVE_EGRESS_NETS` (`tillandsias-enclave,tillandsias-egress`).
- `plan/issues/ACTIVE.md` records (lines 59-62): release `v0.3.260618.1`
  curl-install smoke passed init and the forge lane but **did not exercise
  `--github-login`**; the targeted GitHub-login runtime check was left open.

So the prior "fix" changed the network *name* but its acceptance criterion
(`tillandsias --debug --github-login` completes after a valid token on a clean
post-init install) was never demonstrated. The operator now reports it still
fails, consistent with the fix being incomplete or addressing the wrong layer.

## Suspected code paths

CLI entrypoint and error surface:

- `crates/tillandsias-headless/src/main.rs:301-308` — `--github-login` dispatch.
  On error it prints `Error: {e}` to stderr and `std::process::exit(1)`. This is
  where the CLI "error" the operator sees is emitted.
- `crates/tillandsias-headless/src/main.rs:3828` — `fn run_github_login(debug)`,
  the whole login flow: desktop-session gate, git identity prompt, ensure git
  image, ensure Vault, mint AppRole lease, launch transient helper container,
  paste token, `gh auth status`, write token to Vault.

Primary suspected root cause — egress networks are referenced but never ensured
in the login path:

- `crates/tillandsias-headless/src/main.rs:3876` — the helper container is
  launched with `--network ENCLAVE_EGRESS_NETS`
  (`tillandsias-enclave,tillandsias-egress`, defined at `main.rs:723`).
- `crates/tillandsias-headless/src/main.rs:1425-1464` — `ensure_enclave_network`
  is the only function that creates both `tillandsias-enclave` (line 1439,
  `--internal`) and calls `ensure_egress_network` (line 1429), which creates
  `tillandsias-egress` (lines 1456-1464).
- **`run_github_login` never calls `ensure_enclave_network` or
  `ensure_egress_network`** (verified: no such call in the `main.rs:3828-4010`
  body). The callers of `ensure_enclave_network` are other flows only
  (`main.rs:3611, 4554, 4727, 5757, 6171`). Therefore, when `--github-login`
  runs without a prior in-process network bootstrap — e.g. on a fresh/cleaned
  rootless Podman store, or simply because the dedicated `tillandsias-egress`
  network was never created on this host — `podman run --network
  tillandsias-enclave,tillandsias-egress ...` fails because one or both networks
  do not exist. That surfaces as a generic helper-launch "error" at
  `run_command_silent(run, debug)?` (`main.rs:3891`).

Secondary candidates to rule out (same body):

- `main.rs:3882-3884` — `--cap-drop=ALL --security-opt=no-new-privileges
  --userns=keep-id` combined with dual-homing onto two networks under rootless
  Podman; verify dual-network attach actually succeeds rootless.
- `main.rs:3853` — `vault_bootstrap::ensure_vault_running(debug)` and
  `main.rs:3867` `mint_approle_secret_lease("github-login", ...)`; a Vault
  bootstrap/lease failure would also abort before/around the helper.
- `main.rs:3940-3942` — `gh auth status` verification: if the helper has no
  egress this is exactly where `error connecting to api.github.com` was seen in
  the prior packet.

Tray UX entry path (the operator's "from the tray UX" failure):

- `crates/tillandsias-headless/src/tray/mod.rs:1867-1892` — `handle_github_login`
  spawns `launch_in_terminal("GitHub Login", "tillandsias",
  ["--github-login"])`. The tray does **not** run the login itself; it shells out
  to the same `tillandsias --github-login` CLI path above. So the tray failure
  and the CLI failure are the *same* underlying failure in `run_github_login`.
  Only a terminal-*spawn* failure is mapped to a tray status line
  (`mod.rs:1880-1884`); a failure *inside* the spawned `--github-login` process
  shows up only in the spawned terminal, which on a `.desktop`-launched tray may
  not be visible — making the tray click look like it "fails with an error" or
  does nothing.
- `crates/tillandsias-headless/src/tray/mod.rs:2988-3031` — the GitHubLogin menu
  click handler (force-refreshes cloud projects + `gh auth status` cache after
  login).

Source-level regression pins to be aware of (do not regress):

- `crates/tillandsias-headless/src/main.rs:7864-7878`
  (`github_login_helper_dual_homes_onto_managed_egress_network`) — asserts
  `run_github_login` uses `ENCLAVE_EGRESS_NETS` and not `ENCLAVE_NET`. These are
  *string* assertions over source; they pass even though the networks may not be
  ensured at runtime — i.e. the existing test gives false confidence.
- `crates/tillandsias-headless/src/main.rs:7885-7896`
  (`ensure_enclave_network_also_ensures_egress_network`) — only proves
  `ensure_enclave_network` creates the egress net; it does NOT prove
  `run_github_login` ever calls it.

## Reproduction (as the operator described)

1. On a Linux host, build/install a recent tray (or use the published release).
2. From the command line run `tillandsias --github-login` (add `--debug` for the
   helper container launch line). Enter git identity, paste a valid token.
3. Separately, from the tray, click GitHub Login.
4. Observed: both fail with an error; login has not succeeded in the last
   several builds. Previously worked.

Suggested instrumented repro for the builder:

- Run `tillandsias --debug --github-login` and capture the
  `"/usr/bin/podman" "run" ... "--network" "tillandsias-enclave,tillandsias-egress"`
  line and its exit/stderr.
- Check `podman network ls` before login on a fresh store: confirm whether
  `tillandsias-egress` (and `tillandsias-enclave`) actually exist at that point.

## Work Packet: bug/github-login-failure

- id: `bug/github-login-failure`
- type: bug
- owner_host: linux
- status: open
- severity: high — blocks core GitHub auth; no token reaches Vault, which blocks
  cloud discovery, clone, and the forge/git-mirror credential path. Reproduces
  from both the CLI and the tray, across multiple recent builds.
- capability_tags: [github, auth, headless, cli, tray, podman, networking, vault]
- depends_on: []
- related_packets:
  - `github-login/enclave-egress-regression` (done, but never live-validated)
  - `enclave/network-level-egress-deny`
  - `github-login-vault-native-flow`
- owned_files:
  - crates/tillandsias-headless/src/main.rs  # run_github_login (3828+), dispatch (301), ensure_*_network (1425-1464), ENCLAVE_EGRESS_NETS (723)
  - crates/tillandsias-headless/src/tray/mod.rs  # handle_github_login (1867), GitHubLogin click (2988)
  - crates/tillandsias-headless/src/vault_bootstrap.rs  # ensure_vault_running, mint_approle_secret_lease
- investigation checklist (builder agent next steps):
  1. Reproduce `tillandsias --debug --github-login` on a CLEAN rootless Podman
     store and capture the exact failing command + stderr (do NOT assume; the
     prior packet was closed without this evidence).
  2. Verify whether `tillandsias-enclave` and `tillandsias-egress` exist at the
     moment the helper is launched. They are not ensured inside
     `run_github_login` — confirm this is the failure point.
  3. If the missing-network hypothesis holds: call `ensure_enclave_network(debug)`
     (which also ensures the egress net) at the top of `run_github_login`, before
     the helper `podman run` at main.rs:3868.
  4. If the networks exist but `gh auth status` still fails with
     `error connecting to api.github.com`, audit whether the dual-homed egress
     leg actually provides outbound NAT under rootless Podman, and whether the
     `--internal` enclave net is shadowing default routes; align with the
     working proxy/git-service dual-home pattern.
  5. Rule out Vault bootstrap / AppRole lease failures (main.rs:3853, 3867) as an
     alternate early-abort cause; capture which step actually errors.
  6. Replace the source-string regression test with a runtime/behavioral gate
     that proves the helper launches successfully AND a live (or mocked-egress)
     `gh auth status` succeeds AND the token persists to Vault — the current
     string-only tests gave false confidence and let this regression ship.
  7. Confirm the tray path surfaces the *inner* `--github-login` failure to the
     tray status line (not just terminal-spawn failures), so a `.desktop`-launched
     tray does not look like the click silently failed (mod.rs:1867-1892).
- acceptance_evidence:
  - `tillandsias --debug --github-login` completes after a valid token on a clean
    post-init install and does not print `Error:` / exit 1.
  - The token is persisted to Vault at `secret/github/token`.
  - The tray GitHub Login click results in a stored token and a visible tray
    status reflecting success or a real failure reason.
  - Direct external curl from an ordinary enclave-only container still fails
    (egress denial preserved); forge/proxy egress smoke remains green.

## Events

- type: discovered
  ts: "2026-06-18T00:00:00Z"
  reporter: "The Tlatoani (direct)"
  host: linux
  note: >
    Operator reports GitHub login fails from both the CLI and the tray, across
    the last several builds, having worked before. Investigation grounded the
    likely root cause: run_github_login launches the helper on
    ENCLAVE_EGRESS_NETS but never ensures those networks exist (no
    ensure_enclave_network/ensure_egress_network call in its body), and the prior
    egress-fix packet (d3f4e2f3) was closed without ever live-validating
    --github-login. Filed as an open bug packet for pickup by
    /advance-work-from-plan.

- type: claimed
  ts: "2026-06-18T04:33:47Z"
  agent_id: "linux-tlatoani-opus-worker2-20260618T043347Z"
  host: linux
  note: >
    Claimed bug/github-login-failure for fix. Targeted work packet from
    advance-work-from-plan worker protocol.

- type: progress
  ts: "2026-06-18T04:33:47Z"
  agent_id: "linux-tlatoani-opus-worker2-20260618T043347Z"
  host: linux
  note: >
    Confirmed the hypothesised root cause against the actual code.
    run_github_login (main.rs:3828) launches the gh helper with
    `--network ENCLAVE_EGRESS_NETS` (tillandsias-enclave,tillandsias-egress) at
    main.rs:3884/3899 but never calls ensure_enclave_network or
    ensure_egress_network anywhere in its body. ensure_enclave_network
    (main.rs:1425) idempotently creates the enclave net AND calls
    ensure_egress_network (main.rs:1429) before its early return, so a single
    call ensures BOTH networks — this is exactly how sibling flows do it
    (e.g. run_status_check at main.rs:3611). On a clean/cleaned rootless Podman
    store where tillandsias-egress (or the enclave net) does not exist yet,
    `podman run --network tillandsias-enclave,tillandsias-egress …` fails at
    run_command_silent, which is the operator's CLI+tray login failure (the tray
    shells out to `tillandsias --github-login`, sharing the same failure).

- type: fix-landed
  ts: "2026-06-18T04:33:47Z"
  agent_id: "linux-tlatoani-opus-worker2-20260618T043347Z"
  host: linux
  fix_commit: "62e73c707dc5db690f46e7b0343e0dff13b24eb8"
  note: >
    Minimal fix: added `ensure_enclave_network(debug)?;` in run_github_login
    immediately after `ensure_image_exists(...)` and before the Vault/helper
    `podman run`, matching the idiom of every other enclave-bootstrap flow.
    This idempotently ensures both tillandsias-enclave and tillandsias-egress
    exist before the dual-homed helper launch. Added regression test
    `github_login_ensures_networks_before_helper_launch` (source-level: asserts
    the ensure_enclave_network call appears BEFORE the `--network
    ENCLAVE_EGRESS_NETS` launch arg in run_github_login). The pre-existing
    `github_login_helper_dual_homes_onto_managed_egress_network` test is retained.
    Validated: `cargo build -p tillandsias-headless` clean; both github_login
    unit tests pass; `cargo clippy -p tillandsias-headless` clean;
    `cargo fmt --check` clean; `./build.sh --check` passed (type-check green;
    the dev squid proxy "Failed to start" line is a pre-existing, unrelated
    local-cache warning, not a check failure).
  evidence_open: >
    Full RUNTIME validation still requires an operator / e2e gate and is NOT
    demonstrated here (runtime podman login is not available in this worker
    context): (1) `tillandsias --debug --github-login` completing after a valid
    token on a clean post-init store without printing `Error:` / exit 1;
    (2) the token persisting to Vault at secret/github/token; (3) the tray
    GitHub Login click producing a stored token + visible status. Keep these
    acceptance_evidence items OPEN until an operator runs them. The
    investigation-checklist items 4 (rootless dual-home NAT audit), 6 (live
    behavioral gate), and 7 (tray inner-error surfacing) are likewise NOT
    addressed by this minimal network-ensure fix and remain open should runtime
    validation reveal a deeper egress/NAT or UX-surfacing problem.
