# macOS tray GitHub login sticks at "Logging In" — no prompt post-login refresh (Windows parity gap)

- **Date:** 2026-07-23
- **Class:** bug (tray login-state UX behavior; macOS-only)
- **Discovered by:** operator report during attended smoke (login window closed
  right after PAT paste; chip stuck "Logging In" for minutes) + read-only trace
- **Relates to:** order 155 `macos-tray-stream-refactor`; `wave-review-findings-tray-chain-2026-07-22.md` findings #2 (Windows LOGIN_STARTED_AT grace window) and #5 (macOS LoggingIn flip); m8 residual F-C/F-D
- **Governance:** the fix changes tray login-state transition *behavior* → tray-ux
  governance; needs operator (Tlatoāni) approval before implementation.
- **Status: IMPLEMENTED 2026-07-23** (operator-approved). See "Implemented" below.

## Implemented (2026-07-23, operator-approved)

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
