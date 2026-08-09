# Windows first-launch cold-start findings — v0.4.260809.2 field run (2026-08-09)

Filed from an operator field run of the **published** `v0.4.260809.2` release
(tag == `origin/main` `c3b5b633`), downloaded manually and run from the desktop.
Not a build from a working tree — this is the artifact end users get.

Reported by The Tlatoāni. Diagnosis by `windows-claude-fable-20260809t0625z` on
`windows-next`, against `bdd5de89` (windows-next + origin/linux-next merged).

**Theme.** Every finding below is a *first-launch-after-a-version-bump* defect.
Each one disappears on the second launch, which is why warm-path testing has
never caught them. The operator's own summary named the shape correctly:
lifecycle events that should fire automatically, and long-running work that
never tells the user it is running.

trace: spec:tray-ux, spec:host-shell-architecture, spec:runtime-diagnostics-stream,
order 154 (push streams), order 270 (materialization blackout), order 284/291
(harness health + cold cache), order 332 (image-build announcement), order 439
(harness contract probe), order 459 (opencode curl channel), packet 620-9xpg.

---

## The run, from `tray.log` (`%LOCALAPPDATA%\tillandsias\logs\tray.log`)

```
06:09:34.439  tillandsias tray starting
06:09:49.002  adopted guest wiring is stale — re-injecting bootstrap logic
              guest_version="0.4.260728.1" tray_version=0.4.260809.2
06:10:20.190  Injecting embedded tillandsias-headless binary arch=x86_64
06:10:33.736  VM handshake success (phase=Ready) wire_version=2 attempt=1
06:10:34.018  vm status push subscription established (polls suppressed, SC-07)
06:10:51.790  tray menu click menu_id=github-login action=GithubLogin      <-- F1
06:12:26.889  tray menu click menu_id=project.local.tillandsias.opencode   <-- F2 ends here
```

Two facts to hold onto:

1. The click at 06:10:51 was **accepted and dispatched**, so the login row was
   an *enabled* leaf at that moment — not the disabled `📋 Setting up…` variant.
2. The click at 06:12:26 is on a **project** leaf. `menu_state::build` emits the
   project body **only** under `GithubLoginState::LoggedIn`. So the stored
   credential was valid and the automatic path did work — it simply had not
   reported yet when the menu offered the login leaf.

The same shape recurs in every session in this log — 2026-07-24T07:22:30,
2026-07-28T20:36:03, 2026-07-28T20:38:06 — the operator clicks GitHub Login
within ~30–150s of `subscription established`, every single time.

---

## F1 — The tray offers a sign-in that is already in flight (and already valid)

The operator's hypothesis was that the tray does not try to sign in
automatically. **That part is not what is broken.** The automatic path exists
and is correct: `run_vm_status_push_listener` subscribes to all four topics and
then runs an initial sync (`refresh_github_login` → `refresh_cloud_projects` →
`refresh_local_projects`), precisely because pushes are change-gated and a late
subscriber would otherwise wait forever.

What is broken is that **the tray renders the not-yet-known state as the known
state "signed out"**, and does it with an actionable button.

- `crates/tillandsias-host-shell/src/menu_state.rs:258-267` — `GithubLoginState`
  has three variants: `LoggedOut`, `LoggingIn`, `LoggedIn`. There is **no
  variant for "not observed yet"**.
- `menu_state.rs:332` — `MenuState::initial()` starts at `LoggedOut`.
- `menu_state.rs:458-466` — `LoggedOut` + `login_runtime_ready` renders the
  **enabled** `🔑 GitHub Login` leaf. `LoggedOut` + `!login_runtime_ready`
  renders the disabled `📋 Setting up…` row.
- `notify_icon.rs` `apply_vm_status` — sets
  `login_runtime_ready = (phase == Ready && podman_ready)`.

The two inputs resolve on wildly different timescales, and nothing couples them:

| input | cost | when it lands |
|---|---|---|
| `login_runtime_ready` | one `VmStatusRequest` round-trip | milliseconds after Ready |
| the actual login state | `probe_github_username` → a **container run** in the guest (`remote_projects.rs:384`, `run_git_image_shell`: vault read + `gh auth login` + `gh api user`) | seconds to minutes |

So between "Ready" and "the probe answers" the menu shows an enabled
`🔑 GitHub Login` that is indistinguishable from a genuine signed-out state.
The user does the only thing the menu offers.

**This exact state was specified and then lost in implementation.** The ratified
Observable Streams Contract (`plan/issues/observable-streams-contract-2026-06-30.md`,
boundary B1) writes the required design as
`let (login_tx, login_rx) = watch::channel(LoginState::Unknown);`. Orders
154/230/231/260 landed the push streams faithfully — but `Unknown` never reached
`MenuState`. F1 is that missing variant, nothing more.

Note this is a **shared-layer** defect: `menu_state.rs` is host-shell, so the
macOS tray inherits it identically. The Linux native tray builds its own menu
and needs a separate read.

---

## F2 — `--github-login` runs a multi-minute silent preflight (0 bytes of output)

The operator described the GitHub Login window as "still-blank" and closed it
after ~95s. That is literally true, and the guest proves it:

```
$ wsl -d tillandsias -u root -- ls -la /root/.cache/tillandsias/
-rw-r--r-- 1 root root  0 Aug  8 23:10 github-login-last.log
```

**Zero bytes**, mtime `Aug 8 23:10` local == `06:10Z` — the operator's click.
The wrapper `github-login.sh` (packet 620-9xpg) tees all output to that file, so
an empty file is proof that `tillandsias-headless --github-login` produced no
output at all before the window was closed.

`run_provider_login` (`crates/tillandsias-headless/src/main.rs`) contains exactly
**one** unconditional `println!` — the terminal `authentication complete` line.
Everything before the token prompt is silent or `debug`-gated, and the pinned
test `github_login_prompts_after_infrastructure_preflight` guarantees that work
happens *before* any prompt:

```
ensure_image_exists(git)            →  may build an image
ensure_git_login(debug)             →  EnclaveNetwork → EgressNetwork → CaBundle → Vault → Proxy
check_auth_required_services(...)   →  health gates
run_command_silent(run)             →  helper container start
check_auth_required_services(...)   →  helper health gate
    ...then, finally, the first byte the user ever sees
```

The preflight ordering is correct and should stay. The defect is that a
multi-minute dependency bring-up prints nothing.

This directly advances an open exit criterion on **packet 620-9xpg**
("Tray-menu GitHub Login opens the wrapper, works, and leaves a readable
`github-login-last.log`"): the wrapper deployed and ran, and the log is readable
— it is simply empty, because there was nothing to tee.

Compounding: because of F1 the operator should never have been in this flow at
all. A valid credential was already in Vault.

---

## F3 — Container bring-up is silent; only image *builds* announce themselves

Operator's second launch output (verbatim):

```
[tillandsias] building missing image router (localhost/tillandsias-router:v0.4.260809.2); this may take several minutes
[tillandsias] building missing image inference (...); this may take several minutes
[tillandsias] building missing image forge-base (...); this may take several minutes
[tillandsias] building missing image forge (...); this may take several minutes
```

Those four lines are order 332 working as designed — and they are the **only**
progress the lane emits. Note the version tag: the guest had just been
reconciled to `v0.4.260809.2` at 06:10:20, and `versioned_image_tag` embeds the
version, so **every** image was "missing" and the whole set rebuilt. That is the
multi-minute wait the operator saw, and it is the expected cost of a version
bump — it just needs to say so.

Everything *around* the builds is silent:

- `crates/tillandsias-podman/src/client.rs:1849` — `emit_launch_event` returns
  early unless `debug_enabled`. So `run_container_observed`'s
  `starting`/`running`/`failed` events, which already exist and are already
  well-shaped, are invisible on the default path.
- The `run_opencode_mode` chain — `cleanup_stack_containers`,
  `cleanup_shared_stack_if_no_running_forge`, `ensure_router_running`, proxy,
  `ensure_vault_running`, AppRole mint, git, inference, then the attached forge —
  is entirely `if debug` or silent.

So the user sees "building image" (minutes), then nothing (minutes), then either
an agent or a stack trace. **Order 270 already owns the image-materialization
half of this and is still `ready`.** F3 is the same defect one layer out:
container lifecycle, not image build, and cross-platform rather than macOS.

---

## F4 — First clone raced the git service and self-healed

Also from the operator's second launch:

```
Cloning into '/home/forge/src/tillandsias'...
fatal: unable to connect to tillandsias-git:
tillandsias-git[0: 10.0.42.16]: errno=Connection refused

Cloning into '/home/forge/src/tillandsias'...
remote: Enumerating objects: 58862, done.
...
```

The git container had been *started* but was not yet *listening*; the retry
succeeded. The retry is doing its job, so this is not a user-visible failure —
but "started" is being treated as "ready", which is the same
readiness-vs-liveness gap that Step 15 fixed for the router alias. Worth a
readiness gate rather than leaning on the retry.

---

## F5 — The opencode harness health gate never exercises the path that failed

The operator's first launch reached the forge and then died:

```
Failed to initialize OpenTUI render library: Failed to open library
"/$bunfs/root/libopentui-h3hyjpa5.so": ... cannot open shared object file
Error: [OpenCode] forge session exited: stage 'opencode' attached command exited with status 1
```

`/$bunfs/` is the virtual filesystem inside a **bun single-file executable**;
this is opencode failing to materialize its own embedded native render library.
**The operator relaunched and it worked** — so this is a cold-cache first-run
race, not a broken release.

The structural finding does not depend on pinning the exact race, and it is
this: **every gate we run on the opencode binary is blind to the failure mode
that actually took the lane down.**

- `images/default/lib-common.sh:1803` — `harness_probe` = `-x` +
  `timeout 30 "$bin" --version` + `harness_contract_ok` (flag greps) +
  `opencode_auth_contract_ok`.
- `curl_install_opencode` (`:2164`) → `opencode_validate_or_rollback` uses that
  same probe set.

None of those load OpenTUI — that happens only when a real TUI starts. And the
entrypoint's own guard is just an executable-bit check:

```
images/default/entrypoint-forge-opencode.sh:55  ensure_forge_prebuilt_tools >>/tmp/forge-lifecycle.log &
images/default/entrypoint-forge-opencode.sh:56  ensure_forge_harnesses     >>/tmp/forge-lifecycle.log &
images/default/entrypoint-forge-opencode.sh:71  require_opencode
images/default/entrypoint-forge-opencode.sh:72  [ -x "$OC_BIN" ] || harness_missing_fatal opencode
```

Two consequences, the second worse than the first:

1. A binary that cannot start a TUI passes every gate and reaches the user as a
   raw upstream stack trace.
2. `opencode_record_curl_last_good` (`:2175`) **records that same binary as
   last-good**. The order-284 rollback path can therefore roll back *to* a
   TUI-broken snapshot. The safety net inherits the blind spot.

**Leading hypothesis for the race** (stated as a hypothesis — not reproduced):
the foreground `require_opencode` → `curl_install_opencode` writes
`$HARNESS_CURL_ROOT/opencode/bin/opencode` while the backgrounded
`ensure_forge_harnesses` from line 56 is touching the same tree. A bun SFA reads
**its own executable file** to extract embedded assets, so a binary replaced
underneath a starting process produces exactly this error. `lib-common.sh:2044-2050`
already documents this class of hazard for the npm channel ("a SIBLING
container's background `ensure_forge_harnesses` replaces the shared prefix's bin
symlinks non-atomically") and guards it with the npm-update lock — the curl
channel from order 459 has no equivalent guard.

Verification is cheap and should precede any fix: wipe the harness cache
volume, launch opencode, and capture `/tmp/forge-lifecycle.log` alongside the
failure.

---

## UX-curation governance — why F1/F2/F3 are filed, not fixed

`openspec/specs/tray-ux/spec.md` → "UX curation governance" (operator directive,
verbatim, 2026-07-22) forbids any agent from altering a user-visible surface —
including **enable/disable state**, labels, and **terminal banners shown to end
users** — without explicit prior operator approval recorded on the packet.

F1, F2, and F3 are all exactly that. They are therefore filed
`needs_clarification` with the proposed surface change stated concretely, and
**nothing was implemented**. Proposals are in the ledger fragment; the F1
recommendation deliberately introduces **no new user-visible string** — it
extends the already-approved `📋 Setting up…` row to cover the whole
not-yet-known period, so the fix needs a condition change rather than new UX.

The same spec explicitly exempts diagnostics: *"Diagnostic/agent-facing surfaces
(`--diagnose` output, lifecycle traces, logs) are NOT end-user UX and remain
under normal engineering discipline."* F6 below was implemented under that
exemption.

---

## F6 — IMPLEMENTED: the startup handoff was unmeasurable in the field

Every observation of login/cloud state landed at `debug!`, so a release tray's
log could not answer *"when did sign-in resolve?"*. That is why the timeline at
the top of this document can show Ready at 06:10:33 and a project click at
06:12:26 but **cannot** say when the state actually flipped. The only reason any
of this was ever timeable is the incidental
`WARN build version skew ... ctx="github login refresh"` that appears when guest
and tray versions differ (visible in the 2026-08-05 sessions, absent on
2026-08-09 once versions matched).

Landed on `windows-next` in `crates/tillandsias-windows-tray/src/notify_icon.rs`:

- `apply_github_login` now emits `INFO "github sign-in state resolved"` with
  `from`/`to` labels — **on transition only**, so steady-state pushes stay at
  DEBUG and this cannot become per-push spam. Placing it in the shared funnel
  covers both the poll and push paths with one edit.
- `apply_cloud_projects` emits `INFO "cloud projects resolved"` with a count on
  the **first** confirmed answer (the `cloud_projects_loaded` false→true edge).
- `login_state_label` is a diagnostic-only helper; its strings are never
  rendered in the menu.

Verified: `cargo check -p tillandsias-windows-tray` on the Windows host (the
crate's real paths are `cfg(target_os = "windows")` and are **not** compiled in
WSL — see packet `cfg-gated-tray-code-never-typechecked-2026-07-21`).

With this in place the F1 window becomes a measurable interval in any field
`tray.log`, and any future F1 fix is verifiable rather than asserted.

---

## Handoff

- Branch: `windows-next` (merged `origin/linux-next` per the pre-push gate).
- Packets: `626-r7kq` (F1), `626-w3fn` (F2/F3), `626-p4xd` (F5), plus an event
  on `620-9xpg` recording the 0-byte log evidence.
- F4 is recorded here but not filed as its own packet — it self-heals and is a
  readiness-gate refinement, not a live defect. Fold it into whichever packet
  touches the launch readiness chain.
- **The three UX packets cannot be claimed until the operator approves the exact
  surface change on each.** That approval is the blocking input, not engineering
  effort; F1 in particular is a small, well-bounded change once approved.
