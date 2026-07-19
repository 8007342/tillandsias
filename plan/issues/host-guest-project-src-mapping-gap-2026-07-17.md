# Host↔guest project src is disconnected — cloud clones land in the guest VM, invisible to the host; cloud checkout hangs

- Date: 2026-07-17
- Class: architecture/design gap + bug (project checkout lifecycle)
- discovered_by: operator (The Tlatoāni) live on the fresh Windows guest
  (v0.3.260716.7, clean provision) + windows-bullo-fable5 investigation
- Related: order 342 (macos-forge-owned-checkout-isolation — the INVERSE
  concern: isolating the operator checkout from the forge), spec
  host-shell-architecture (scanner.local-project-discovery), order 326
  (guest /home/forge/src ownership), the forge_src_isolation host-mount vs
  src-host staging branches in build_opencode_forge_args /
  build_forge_agent_run_args.

## Operator's observation (verbatim intent)

"There was no 'src' in my home dir. Tillandsias' own checkout 'succeeded'
and is loading/creating containers, but there's still no src dir at all.
Antigravity launched fine, I authenticated and prompted the model, but there
was no project checkout — it might have failed because it missed the parent
'src' folder not existing. The cloned project is listed in the tray as
local, maybe it's local in the guest VM instead of the host? That home/src
folder might need to be mapped between the host and the guest, so the guest
can mount projects into the containers. It's now trying to clone another
project (I manually created the parent src folder) and launched a terminal
at the same time — they're all hung."

## Confirmed mechanism

- `projects_root()` (crates/tillandsias-headless/src/main.rs:3366) runs
  INSIDE the guest and resolves to **guest** `/home/forge/src` (the
  order-326 forge dir) — or `$TILLANDSIAS_IN_VM_PROJECT_ROOT` /`~/src`.
  So `--cloud owner/repo` clones into the GUEST filesystem
  (`/home/forge/src/<repo>`), NOT onto the host.
- The forge container mount DOES work from there: the running antigravity
  lane shows `/home/forge/src/tillandsias -> /home/forge/src/tillandsias`
  (+ the order-342/gitdir facade mounts). So guest→container mounting is
  fine; the operator's "mapping needed to mount into containers" is half
  right — the mount works, but the LOCATION is guest-only.
- The HOST `C:\Users\bullo\src` (which the tray's host-side
  scanner.local-project-discovery watches — the repeated
  `Watch path does not exist, skipping watch_path=C:\Users\bullo\src` log)
  is a SEPARATE filesystem from guest `/home/forge/src`. The tray ALSO
  ingests a VM-side local-projects list (notify_icon.rs:1242), so
  guest-cloned projects surface in the menu as "local" — they are local,
  but local IN THE GUEST. Hence the confusion.
- Cloud checkout FAILED this session: only `tillandsias` is in guest
  `/home/forge/src`; the cloud project the operator attached never landed
  (clone hung). Likely cause: on this fresh guest the operator authed the
  provider (Antigravity/Gemini) but the GitHub token needed for the clone
  was absent/unfinished (github-login not completed into the fresh vault),
  so the clone hung with no visible error — plus a terminal launched
  concurrently, both wedged.

## The design question (operator decision)

Two models for where operator-facing project checkouts live:

- **A. Guest-native (current)**: projects live in guest `/home/forge/src`;
  forge mounts from the guest path. Simple for the container, but the
  operator cannot see/edit projects from the host except via
  `\\wsl.localhost\tillandsias\home\forge\src\...`, and the host-side tray
  scanner watches an unrelated empty `~/src`. Confusing; "where did my
  clone go?"
- **B. Host-mapped (operator's lean)**: a host projects dir (e.g.
  `%USERPROFILE%\src` / `~/src`) is MAPPED into the guest at
  `/home/forge/src` (WSL2 drvfs / virtiofs on VZ), so a single project
  location is host-visible+editable AND guest-mountable into containers.
  The tray's host scanner and the guest both see the same set. Matches the
  operator's mental model and removes the disconnect.

Tension to resolve: order 342 deliberately ISOLATES the operator checkout
from the forge (read-only `src-host` staging, forge-owned working copy) to
avoid uid/ownership and mutation collisions. A naive host↔guest bind of
`~/src` re-introduces exactly those (drvfs uid mismatch, the "dubious
ownership"/EACCES class). So model B must reconcile with 342: likely a
host-mapped SOURCE that the guest still materializes a forge-owned working
copy from (clone/copy transport), not a raw rw bind of the host dir into the
container.

## Immediate (ephemeral) remediation for the hung state

Per the 2026-07-17 runtime-ephemerality directive: a hung clone/lane is not
to be nursed — destroy and recreate it. Exiting the agent + re-attaching
(after github-login completes so the clone has its token) is the correct
move; the operator already chose to exit. No host state is lost (nothing of
value was on the host to begin with — that IS the gap).

## Shaping / next actions

- Decide model A vs B (operator/coordinator). If B: design the host↔guest
  project mapping that reconciles with order 342 (host-visible source +
  forge-owned in-container working copy), on both WSL2 and VZ.
- Fix the cloud-checkout failure UX: a clone that cannot proceed (missing
  GitHub token, parent dir, network) must FAIL LOUD with a recreate/next-
  step message, never hang a lane + terminal silently (ties to the
  error-message policy in the runtime_ephemerality methodology).
- Make the tray's "local" label unambiguous about host-vs-guest origin
  until the mapping unifies them.
