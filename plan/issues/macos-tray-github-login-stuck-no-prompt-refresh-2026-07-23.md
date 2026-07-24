# macOS tray GitHub login sticks at "Logging In" — no prompt post-login refresh (Windows parity gap)

- **Date:** 2026-07-23
- **Class:** bug (tray login-state UX behavior; macOS-only)
- **Discovered by:** operator report during attended smoke (login window closed
  right after PAT paste; chip stuck "Logging In" for minutes) + read-only trace
- **Relates to:** order 155 `macos-tray-stream-refactor`; `wave-review-findings-tray-chain-2026-07-22.md` findings #2 (Windows LOGIN_STARTED_AT grace window) and #5 (macOS LoggingIn flip); m8 residual F-C/F-D
- **Governance:** the fix changes tray login-state transition *behavior* → tray-ux
  governance; needs operator (Tlatoāni) approval before implementation.
- **Status: root cause CORRECTED 2026-07-23** — the original "no prompt refresh"
  framing was SECONDARY; the primary cause is a lost-token-persistence failure
  hidden by an `exec`-swallowed error. See "Correction" below.

## Correction (2026-07-23): the real root cause is lost token persistence

End-to-end trace verdict (the stuck "Logging In" is NOT primarily a refresh gap):

- macOS GitHub Login runs `tillandsias-headless --github-login`
  (`crates/tillandsias-headless/src/main.rs` `run_provider_login`): prompts git
  name/email + PAT, runs `gh auth login` / `gh auth status`, THEN writes the token
  to Vault `secret/github/token` (`main.rs:7051-7076`, synchronous + read-back
  verified).
- If any post-paste step fails (gh egress/proxy, CA, or the vault write), the
  process exits **before** the Vault write — the PAT is collected but never
  persisted.
- The launcher wrapped it as `exec tillandsias-headless … || (echo … && sleep 10
  && false)` (`crates/tillandsias-host-shell/src/pty/mod.rs`). Because of `exec`,
  the `|| (…)` fallback is DEAD CODE — a non-zero exit vanishes with no message
  and no pause = "terminal closes too quickly after paste".
- The status probe (`probe_github_username` → Vault `secret/github/token`,
  `remote_projects.rs:384`) is CORRECT and reads the same path; with nothing
  written it returns logged-out forever, so the chip never reaches LoggedIn.
- The prompt ~2s poll + 90s grace (the "UX-refresh work" below) then **masked**
  the failure, holding "Logging In" instead of falling back to the actionable
  leaf.

### Resolution (root cause found + fixed 2026-07-23)

**Root cause = missing SELinux relabel on the login container's CA mount.** The
ephemeral `tillandsias-github-login-<pid>` container mounts the CA bundle WITHOUT
`relabel=shared`/`label=disable`, so on the SELinux-enforcing Fedora guest the CA
at `/etc/tillandsias/ca.crt` is present but UNREADABLE by `container_t`.
`vault-cli.sh`'s `require_cacert()` gate trips ("CA bundle not readable") and the
in-container Vault write (`main.rs:7051-7064`) aborts BEFORE any token bytes reach
Vault. The status probe works because it sets `--security-opt=label=disable`, and
every peer CA mount uses the canonical `relabel=shared` form (asserted
`main.rs:~16733`) — the login container was the sole omission (the 2026-07-22 CA
fix added the mount but missed the relabel). gh egress is NOT the cause: squid
`ssl_bump splice all` splices github.com with public CAs, and the login container
has the probe's exact network + proxy env.

**Fix:** add `relabel=shared` to the CA mount (`main.rs:6941`). One line; matches
the canonical form + the probe's readability.

**Reverted (operator anti-polling / anti-self-DDoS directive):** the earlier
tray-side "fast confirm" (a 2s cadence that made the GUEST run a
`probe_github_username` CONTAINER every tick just to refresh a chip — literally
self-DDoS) and the `exec`-removal (which risked breaking the interactive
git-identity stdin read — the login hung there on the exec-removed build) were
both REMOVED. Login-state reflection reverts to the existing push/fallback.
PROMPT, event-driven reflection (a login-state event pushed WHEN the token is
persisted — zero polling) is the flow-FSM/event-channel research
(`plan/issues/research-flow-state-event-channel-2026-07-23.md`,
`research-auth-flow-state-machines-2026-07-23.md`). The passive
`apply_login_state` grace guard is retained (it performs no I/O). Idiomatic-layer
call rate-limiting / coalescing is filed separately per the operator's
anti-DDoS directive.

## UX-refresh work (secondary fix — still valid; grace now 60s)

Ported the Windows pattern into `crates/tillandsias-macos-tray/src/action_host.rs`:
1. **Grace window** in `apply_login_state` (the single choke for all login-state
   updates, poll + push): a fresh `LoggingIn` is not downgraded to `LoggedOut`
   for `LOGIN_GRACE` (90 s) — anchored by `mark_login_started()` on the login
   click (`LOGIN_STARTED_AT_MS`). `LoggedIn` always applies immediately.
2. **Prompt confirm poll** in the vm-status poller loop: while
   `login == LoggingIn`, `poll_github_login_once` runs every ~2 s independent of
   the tick%10 cadence AND the push-health suppression gate, until login resolves.
3. **Fast tick** (2 s vs 30 s) while a login is pending.

Net: a completed interactive `gh auth login` flips the chip to "Logged in" in
~1-2 s instead of minutes/never. Verified: `cargo build`/`cargo test -p
tillandsias-macos-tray` green (77 passed). Final "~2 s" latency confirmation is
operator-attended (requires a real PAT paste on relaunch).

## Symptom

After an interactive `tillandsias --github-login` (the `gh auth login` PTY
session in Terminal.app via `screen /dev/ttysNNN`), the macOS tray chip stays on
"Logging In" indefinitely — "a second or two" expected, minutes-to-forever
observed. The tray process is idle (0% CPU) while stuck, so it is NOT grinding
through slow IO — it has simply stopped re-checking.

## This is NOT the Windows sync/unbuffered-IO choke

The macOS host↔VM IO path is already async + buffered:
- `pty_vsock_bridge.rs` — tokio reader/writer tasks, `AsyncRead/AsyncWrite`,
  `tokio::io::split`, framed `[len BE][postcard]`, bounded mpsc backpressure.
- `vsock_client.rs` — async `Client` (`.await` send/recv, `connect_with_handshake`
  with timeout + backoff), single open stream.

So the "make it async + buffered" remedy that fixed Windows does not apply here;
the macOS defect is architectural (missing prompt refresh), not slow bytes.

## Root cause

Login state leaves `LoggingIn` only via (a) a guest `LoginStatePush` or (b) the
fallback `poll_github_login_once`. On macOS:

1. The GithubLogin handler (`action_host.rs:1421`) flips to `LoggingIn` and calls
   `attach_pty(GithubLogin)` (`:1459`), which spawns the interactive terminal and
   returns. The PTY/bridge tasks "run detached … unwind naturally when the
   session closes" (`:1144-1147`). **There is no post-login refresh** and no hook
   on login-session completion.
2. The fallback `poll_github_login_once` runs only every ~10 ticks (~5 min,
   `:2500-2504`) AND is **suppressed entirely while the push subscription is
   healthy** (`should_poll_fallback`, `:2530`).
3. So confirmation depends on the guest emitting a `LoginStatePush`
   (`set_login_state` pushes on observed transition, `vsock_server.rs:268`).
   For the interactive-login path that re-observation is not reliably triggered,
   and with a healthy push the fallback poll can't cover for it → stuck.

Windows does not have this gap: it calls `refresh_github_login(hwnd).await`
immediately after the login flow (`notify_icon.rs:1785`) and guards a fresh
`LoggingIn` against premature `LoggedOut` downgrade with a `LOGIN_STARTED_AT`
grace window (wave-review #2).

## Proposed fix (macOS-only, mirrors Windows; operator-approval-gated)

Port the Windows pattern into `action_host.rs`:
1. **Prompt post-login confirmation:** while `login == LoggingIn`, poll
   `poll_github_login_once` on a fast cadence (~2 s) independent of the
   push-health suppression gate, applying the result via the existing
   `apply_login_state` + main-thread `dispatch_rebuild` path — so a completed
   login flips within a second or two.
2. **Grace window (LOGIN_STARTED_AT):** do NOT apply a `LoggedOut` downgrade for
   the first N seconds after the login click (the user is mid-paste); apply
   `LoggedIn` upgrades immediately; apply `LoggedOut` only after the grace window
   (real failure/abandon). Prevents the fast poll from reverting `LoggingIn`
   before the user finishes.
3. Bound it: the fast cadence is active only while `LoggingIn`; it self-resolves
   to normal cadence once the state settles (no unbounded loop —
   `vm-provisioning-lifecycle.invariant.launch-no-unbounded-loop`).

## Operator workaround (no rebuild needed)

Quit and relaunch the tray. A fresh launch runs `poll_github_login_once` at
tick 0 (before the push subscription is healthy, so the fallback is not yet
suppressed), so it shows the TRUE login state within its first status cycle:
- chip shows **Logged in** → the earlier login DID land (token in Vault); only
  the in-session refresh was missing.
- chip shows **GitHub Login** (logged out) → the interactive login did not
  persist a token; log in again.

## Repro

1. Launch tray on a provisioned VM; wait for ready.
2. Click GitHub Login; complete `gh auth login` in the popup terminal.
3. Observe chip stuck "Logging In" (does not resolve within seconds/minutes while
   the push subscription is healthy).

## Windows evidence 2026-07-24 (cross-platform confirmation + mechanism)

Reproduced on windows with tray 0.3.260724.1 against guest 0.3.260721.1
(operator live): login CLI succeeded end-to-end (vault write + "GitHub
authentication complete"), menu stayed login-gated indefinitely. Event
Log shows exactly ONE github-login refresh at tray start (00:12:10, ctx
flagged by the version-skew WARN) and none after. Mechanism (windows
notify_icon.rs): steady-state polls are SUPPRESSED while the push
subscription is healthy (SC-07/SC-16, should_poll_login_and_cloud);
the login transition must be PUSHED by the guest, and a guest that
predates the login-state publisher (or a login performed by a separate
CLI process the guest service does not observe) never pushes it. So the
gate is healthy-push + silent-guest = permanently stale menu. Fix
directions: (a) the login PTY intent already tells the tray a login was
attempted — fire a bounded fast-poll burst after the login terminal
closes; (b) guest-side: the CLI login path should poke the service
publisher (or the service should watch the vault token path). Restarting
the tray (startup poll) or reprovisioning to a current guest clears it.
