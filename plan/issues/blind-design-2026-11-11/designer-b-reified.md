# reified.md — Designer B's design on the real constraints

The same design as `design.md`: one Rust binary (tray, CLI, reconciler), one
`gateway` container, one forge image family, state in the OS keyring, podman
labels and one small config directory. Sections not mentioned are unchanged.
Every change is marked `[R:<reason>]`: an operator ruling (memory name), an
answer in `answers.md` (B-Qn), or an open operator question (OQ-n in
../../operator-questions.md). Nothing is taken from the existing
implementation unless a ruling forces it.

## 0. Status of the blind assumptions

| Blind assumption | After answers |
|---|---|
| Tray-only near-zero; nothing runs when nothing is launched | HELD: OQ-2 |
| CLI fallback acceptable | HELD: OQ-3 |
| User can use a terminal we open, never types setup commands | CONFIRMED (end user, not power user) `[R:installer-is-for-end-users-no-prompts]` |
| Quit asks "leave running / stop" | KEPT. The existing system stops on quit by spec, but that is not an operator ruling, so it is not imported. |
| One machine | HELD: OQ-4; nothing below may foreclose more `[R:methodology capability_ladder]` |
| Local-only projects, offline mirror | CHANGED, §3 |
| Shared podman store | CHANGED, §5.1 |
| Floor 2c/4 GB | HELD: OQ-1 |
| OS keyring instead of a vault service | KEPT: an OS-encrypted store is what the ruling allows `[R:no-plaintext-credentials-at-rest]` |
| No nested or sibling containers | CHANGED, §6 |

## 1. Tray process model

- One binary, native tray per platform, no toolkit, no timers: unchanged.
- **Progress** is one non-interactive status line (step n of m or a percentage
  when known); the tooltip may repeat it. The icon blushes while containers
  are created, shows pups when done, resets on the first menu open.
  `[R:image-build-retry-and-tray-feedback-ruling]`
- **No "Restart?" item.** A failed start or pull is retried automatically in
  the background on exponential backoff a small number of times, then shown as
  failed in a curated sentence. The user is never told a later attempt
  succeeded; agents get `retry_after`. `[R:image-build-retry-and-tray-feedback-ruling]`
- **Control-stream reconnect.** Backoff while disconnected is capped at 5
  minutes instead of 60 seconds, and an OS resume notification triggers an
  immediate attempt; the retry exists only while a cloud is believed up. Listed
  for approval as a cadence (≤ 12 wakeups/hour after the first minutes, zero
  when connected). `[R:polling-cadence-needs-operator-approval]`
- **Approvals** are answered per forge instance; the window is titled
  `<Agent>/<Project>/Launched at <date time>`. `[R:operator-approval-and-ux-rulings 2026-10-26]`
- **Cloud-cost actions** (pushing or merging into an integration branch,
  opening a pull request, dispatching CI, creating or refreshing a hosted
  resource, a deploy) need an OS-verified approval (Touch ID, Windows Hello,
  FIDO2 key or fingerprint on Linux), recorded on the commit or push. The tray
  gains this one dialog. `[R:operator-approval-and-ux-rulings 2026-10-25]`
- Menu wording is curated; raw sizes are not shown in ordinary menus (the
  per-project volume sizes move into a disk bar in an informed dialog).
  `[R:operator-approval-and-ux-rulings — curated messages, disk bar]`
- "Open <project>" opens the user's terminal on the agent: unchanged, and it
  is what the operator asked for. `[R:forge-agents-visible-not-headless]`

## 2. State

| State | Home | Change |
|---|---|---|
| Secrets | OS keyring | unchanged. If the keyring cannot be opened, stored sign-ins are discarded and the tray starts sign-in again; no salvage. `[R:vault-is-thrown-away-not-recovered]` |
| Desired state, manifest | one root: `~/.tillandsias` on Linux, the most contained single equivalent elsewhere, not scattered platform config dirs | `[R:operator-approval-and-ux-rulings — storage]` `[R:media-studio-and-storage-direction]` |
| Actual state | podman labels, in the product's own store | §5.1 |
| `<project>-work` | per forge **instance**, not per project | `[R:operator-approval-and-ux-rulings 2026-11-01]` |
| `<project>-home` | holds tool installs only. Agent session history is **not** kept across forge close. | `[R:forge-logs-die-with-the-forge]` |
| cache | unchanged; wiped and recreated on corruption | `[R:media-studio-and-storage-direction]` |

## 3. Topology

- **Gateway**: one Rust container with the four functions, unchanged, plus the
  appliance call in §6.
- **Credentials into the gateway.** Not podman secrets (the default secret
  driver stores data unencrypted on disk). At `up` the tray reads the keyring
  and writes each credential once to the gateway's stdin / control socket; the
  gateway holds them in memory only. On macOS/Windows nothing credential-shaped
  touches the VM disk. `[R:no-plaintext-credentials-at-rest]`
- **Git sign-in.** A GitHub App device flow started from the tray is the one
  source of git identity and of the relay's credential; the "prompt for a git
  credential in a native dialog" path is removed. Commits are authored as the
  human; agents are credited in `Co-Authored-By`. Agents never start a
  sign-in. `[R:open-it-browser-direction — git identity]` `[R:agents-never-start-a-sign-in]`
- **Project = hosted repository.** `open <owner>/<repo>`; a host path is
  refused. The bare-repo backend for projects with no remote and the "push the
  current host branch first" offer are removed. `[R:forges-launch-from-the-cloud]`
- **Several forges per project.** A second "Open" on a project creates a new
  instance with its own work volume on the same project network; both push
  through the same relay; the gateway sends each a `peer_pushed` event on
  `/v1/events`. Per-project identity by network interface is therefore no
  longer enough to tell instances apart: each instance gets its own listener
  address (or socket) on the gateway. `[R:operator-approval-and-ux-rulings 2026-11-01]`
- **Relay ref policy.** `refs/heads/forge/*` default unchanged. A push that
  lands on an integration branch, and opening a pull request, need the
  OS-verified approval. `[R:operator-approval-and-ux-rulings]`
- **Forge image.** Prebuilt and pulled by digest: unchanged. Published only by
  an intentional release build, at most one cloud build a day. Optional,
  network-flaky tools install in the background after the forge is usable,
  behind first-use shims that report "still installing". `[R:one-cloud-build-per-day]` `[R:flaky-installs-go-background-direction]`
- **Logs.** Containers run with a log driver that writes only to memory-backed
  storage (not the journal on disk). `doctor` bundles contain no raw log text
  from a closed forge; a forge reads only its own output and that of
  containers it started. No size cap on a live forge's logs.
  `[R:forge-logs-die-with-the-forge]` `[R:forge-log-visibility-ruling]`
- **Preview.** `ports/expose` still returns a URL, but "open" launches an
  isolated browser fully separate from the user's personal accounts (a
  container on Linux, Wayland only; the native engine in an isolated guest
  elsewhere), not the default browser. `[R:open-it-browser-direction]`
- Services cut (§3.4): unchanged, except "Reverse proxy / on-demand
  containers" — see §6.

## 4. Lifecycle

- Cold and warm start: unchanged. A large first download gets a fully informed
  dialog with a disk bar; durations are stated as honest ranges.
  `[R:operator-approval-and-ux-rulings]`
- Stop, quit, idle suggestion: unchanged.
- Rebuild-not-snapshot: unchanged; on every stable release each reused
  component is upgraded or thrown away and recreated. `[R:durable-instructions-and-auto-upgrade-direction]`
- Updates: check on menu open when older than a day: unchanged (event-driven).
- Uninstall asks exactly once, behind a prominent irreversible-action warning
  naming the sign-ins; install never asks anything. `[R:installer-is-for-end-users-no-prompts]`

## 5. Substrate

### 5.1 Linux
- Private podman store under `~/.tillandsias` (own `--root`/`--runroot`), not
  the user's store. `doctor` explains why the user's `podman ps` is empty.
  `[R:operator-approval-and-ux-rulings — own podman store]`
- Podman itself stays a prerequisite; the product never uses sudo and never
  layers packages; `doctor` says what is missing in one curated sentence.
  `[R:no-sudo-no-layering-no-licence-without-operator]`
- The tray refuses to start without disk swap and shows instructions.
  `[R:operator-approval-and-ux-rulings — swap is mandatory]`

### 5.2 macOS
- Dedicated podman machine named `tillandsias`: unchanged, on the **libkrun**
  provider rather than the Apple hypervisor provider. `[R:media-studio-and-storage-direction 2026-10-28]`
- Bundling the podman client and VM helpers: each bundled component's licence
  is put to the operator before it ships. `[R:no-sudo-no-layering-no-licence-without-operator]`
- Swap is configured in the machine. `[R: swap is mandatory]`
- Intel Macs: a separate obligation row with its own verdict, not "same path".
  `[R:obligations-hold-per-platform]`

### 5.3 Windows
- Own imported distro, keepalive holder, `wsl --terminate` only: unchanged.
- The installer writes the swap and memory-reclaim keys without asking; the
  blind "we do not edit `.wslconfig`" is withdrawn for those keys only.
  `[R:operator-approval-and-ux-rulings — swap forced on WSL]` `[R:installer-is-for-end-users-no-prompts]`
- ARM64 Windows: a separate obligation row. `[R:obligations-hold-per-platform]`

## 6. Agent-facing interface

Implicit interface: unchanged. Explicit API: the five calls unchanged, plus:

| Call | Purpose | Approval |
|---|---|---|
| `POST /v1/appliances/start {kind}` / `stop` / `GET status` | Start a sibling container from a fixed catalogue (web container for the project's app, browser, studio) on the caller's project network. The gateway forwards the request on the control stream; the tray runs podman. No container gets the engine socket. Nothing in the catalogue auto-starts and none has a tray menu entry. | none for catalogue kinds |
| `GET /v1/events` | adds `peer_pushed` | none |

"Container control is deliberately absent" is withdrawn for catalogue
appliances only; arbitrary container control stays absent.
`[R:operator-approval-and-ux-rulings 2026-11-02]`

Model relay errors say honestly that a metered provider bills the user's
account even at zero cost. `[R:operator-approval-and-ux-rulings 2026-10-26]`

## 7. Budgets

Unchanged as proposals; all wait on OQ-1 and OQ-2. Each is reported per
platform with its own verdict. `[R:obligations-hold-per-platform]`

## 8. Failure modes — rows that change

| Failure | Change |
|---|---|
| Gateway crashes | automatic bounded retries, then "failed" in a curated sentence; no "Restart?" `[R:image-build-retry-and-tray-feedback-ruling]` |
| Keyring unopenable | discard and sign in again `[R:vault-is-thrown-away-not-recovered]` |
| No disk swap | new row: refuse to start with instructions `[R: swap is mandatory]` |
| Disk full | also checked before creating a work volume `[R:media-studio-and-storage-direction]` |

## 9. Languages

Rust for all three binaries: unchanged. Per-project hooks, if added, are Lua.
No shell scripts, Python or jq in the product or install path; installers use
native formats. `[R:operator direction — Lua/Rust/Go, no jq]`

## 10. Inventory after reification

The blind five items, plus: one OS-verified approval dialog in the tray, the
appliance catalogue in the gateway API, and an isolated preview browser.
Each was added by a ruling, not by preference.
