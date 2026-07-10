# macOS tray attended parity smoke — findings (2026-07-10, operator + agent session)

- session: The Tlatoāni at the tray + macos agent
  macos-Tlatoanis-MacBook-Air-fable5-20260710T0202Z (order 257 claim)
- build under test: osx-next @ efacbcad + this session's fixes, installed to
  `~/Applications/Tillandsias.app`, freshness gate PASS
- harness: `scripts/macos-tray-ax-smoke.sh` (AX enumeration + click +
  screenshot; Accessibility permission granted live)

## Verified live this session

- **Icon + menu (checklist 1)**: AX `icon-present` ok; menu enumerates.
- **GitHub login popup (checklist 4) → cell DONE**: menu click → popup
  Terminal window (screen attached to the PTY, never inline) → full flow with
  a real PAT, completed successfully TWICE. First attempt on this boot, no
  exit 125 (order 259 fix holding on the installed build).
- **Status chip healthy path (checklist 7, healthy half)**: after fix F-A
  below, menu renders `🟢 Ready · tillandsias-in-vm` live.

## F-A (FIXED this session): status chip clobbered back to "Booting…" by rebuilds

`render()` derives the status row from `MenuState.status_text` on every menu
rebuild, but `apply_vm_status` only wrote the phase text onto the NSMenuItem
directly — the rebuild triggered by the same transition resurrected the
`BOOT_STATUS_TEXT` default. Menu showed "🔵 Booting…" indefinitely while
stderr logged `phase=Ready` (caught by AX enumeration + screenshot; the
"Enclave status indicator" parity cell could never pass). Fix: sync
`MenuState.status_text` in `apply_vm_status` and the wire-unreachable poll
path; regression pin test. Verified live post-fix. Windows heads-up: check
whether notify_icon.rs shares the render-from-state clobber pattern.

## F-B (FIXED this session): virtio-fs ~/src mount evaporates after first boot

Cloud-init mounts `home-src` at `/home/forge/src` on FIRST boot only — no
fstab entry, no mount unit. Every later boot scans an empty dir:
`EnumerateLocalProjects` truthfully returns `[]` ("no projects yet" in the
menu despite `~/src/tillandsias` on the host) and `fetch-headless.sh` cannot
see the tray-staged guest binary (guest headless silently pinned to
provisioning-day version). Fix: persist `home-src /home/forge/src virtiofs
nofail 0 0` in `/etc/fstab` via cloud-init; drift-pinned in the vz.rs source
test. VERIFICATION REQUIRES RE-PROVISION (cloud-init change) — see residuals.

## F-C (tray-side mitigation FIXED; headless side OPEN → promoted order 267):
cloud list never refreshes after login

`set_cloud_projects` (the CloudProjectsPush source) is called ONLY from the
`CloudRefreshRequest` handler; SC-07 suppresses exactly that request while
the push stream is healthy; the initial-sync prime ran pre-login (empty).
Post-login the menu shows "no repos" forever. There is a periodic guest
probe for login presence (60s) but none for cloud. Tray-side mitigation
landed: on a LoginStatePush logged-in transition the macOS reader now sends
one CloudRefreshRequest prime on the push connection (windows should mirror
— order 154 flag). Headless-side residual (linux, order 267): the login
probe's logged-in transition should also refresh the cloud list guest-side
so ALL subscribers converge without a tray-side prime.

## F-D (UX, OPEN): login-state propagation lag misleads the operator

After a successful login the menu can show "GitHub Login" (logged-out) for
up to ~60s+ (periodic probe cadence) with zero in-progress feedback — the
operator reasonably re-ran the whole login (it succeeded twice; name/email
pre-filled on the second pass). The F-C tray prime narrows the window after
the push arrives, but the 0-60s guest-side gap and the silent menu remain.
Ideas (not designed here): headless pushes LoginState immediately on the
login satisfier's completion; tray marks the login item "in progress…"
while the PTY session is open.

## F-E (OPEN): one-shot CLI modes cannot run against a live tray

`--exec-guest` / `--list-cloud-projects` unconditionally start their own VM;
with the tray holding the disk they fail with the opaque VZ error `Invalid
virtual machine configuration. The storage device attachment is invalid.`
Fine in e2e (nothing else running), broken for a real operator (tray always
running). Wanted: detect the live VM (e.g. try the control wire first, or a
friendly "tray owns the VM" error), or route one-shots through the running
VM. Blocks in-session guest forensics.

## F-F (harness nit, OPEN): `macos-tray-ax-smoke.sh pty-dump` session resolution

`pty-dump` reported "No screen session found" while `screen -ls` listed the
login session (`86884.ttys002...` attached). Workaround: explicit
`screen -S <session> -X hardcopy`. Harness should resolve via `screen -ls`
first match (or take a session arg).

## F-G (UX nit, OPEN): login popup ends in a dead shell

After flow completion the popup window prints `[screen is terminating]` and
drops to a bare prompt. Should close itself or print a clear success line.

## Round 2 (fresh provision @ b365deaf, operator re-login) — fix verdicts + new findings

- **F-B mount fix VERIFIED (first boot)**: local-projects populated pre-login
  (1 entry), and the in-VM lakanoa clone into `/home/forge/src` appeared in
  host `~/src` with its files — share live end-to-end. fstab persistence
  (second boot) verified separately below.
- **F-C prime VERIFIED**: the instant LoginStatePush arrived, the tray primed
  and rendered 23 real repos (log lines adjacent). Cloud overflow row click
  dispatched CloudOverflow.
- **F-D CONFIRMED at full strength**: operator had time to run the login
  THREE times before the guest's 60s presence probe pushed the state. Order
  267 is the fix (satisfier-completion push).

### F-H (NEW, promoted order 270): first-use agent attach dies silently during in-VM image materialization

On the fresh VM, cloud attach (lakanoa) streamed the clone lines then went
silent; local OpenCode attach opened a Terminal that printed
`[screen is terminating]` immediately. Guest journal (via SSH): two `podman
image build` events in flight — the forge image chain builds from the recipe
on first use, multi-minute and network-bound, while the attach PTY shows
NOTHING and the host-side attach worker gives up/closes the PTY silently
(screen sessions gone from `screen -ls`). Operator experience: dead/blank
terminals with no explanation, indistinguishable from a hang. Wanted:
stream materialization progress into the attach PTY (or at minimum a
"building forge image, first use takes minutes…" line + keep the PTY open
until the build concludes), and a loud error line when the worker gives up.

### F-I (NEW, filed): status chip event text goes stale

Chip stayed `🟢 Ready · Securing Vault` long after vault bootstrap
completed — last_event only changes when the guest emits a NEW event, so the
last provisioning event lingers indefinitely as if still in progress.
Cosmetic but misleads ("has been Securing Vault for a while now" — operator,
live). Consider clearing the event suffix after Ready settles, or
timestamping it.

### F-H severity upgrade (SSH post-mortem)

The in-VM forge build runs as a child of the attach session: when the host
worker closed the PTY it reaped the build. Evidence: empty-ID `image build`
journal events for both attempts, 59 dangling layers, no tagged forge
image, zero build processes, load 0.05. First-use attach can NEVER succeed
on a slow network; retries only advance the layer cache. Order 270 gained
exit criterion 4 (build survives PTY loss). Session workaround: forge-base +
forge built manually over SSH under nohup (headless-identical tags) to
unblock the InteractiveStream / 6-leaf verification.

### Also observed

- Guest journal is dominated by full-label podman exec/exec_died event pairs
  every 60s (vault liveness + login presence probes) — forensics
  signal-to-noise problem, batched into order 270's scope note.
- The headless logs entire `gh api` JSON bodies (private-repo metadata) into
  the journal — noise + mild privacy concern, batched into order 270's
  scope note.
- SELinux is permissive in the guest: steady AVC denial stream from
  vault_container_t (curl exec, port 8200 name_connect) that would be
  ENFORCING breakage — pre-existing hardening debt worth a dedicated packet
  when SELinux enforcement lands on the roadmap.

## Residual verification (needs fresh provision + one more login)

Re-provision with F-B's fstab fix + current headless, re-login (operator),
then verify: local 🏠 submenu lists real ~/src projects; cloud ☁️ submenu
populates via the F-C prime; per-project 6-leaf submenu (checklist 3);
Attach Here (checklist 6); induce degraded/failed chip (checklist 7).
