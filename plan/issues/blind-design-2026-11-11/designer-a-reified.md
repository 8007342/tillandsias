# reified.md — Designer A's design on the real constraints

The same design as `design.md` (tray → substrate with systemd/Quadlet → region
of socket-activated `regiond` services plus forges). Sections not mentioned are
unchanged. Every change is marked `[R:<reason>]`, where the reason is an
operator ruling (memory name), an answer in `answers.md` (A-Qn), or an open
operator question (OQ-n in ../../operator-questions.md). Nothing is taken from
the existing implementation unless a ruling forces it.

## 0. Status of the blind assumptions

| Blind assumption | After answers |
|---|---|
| Floor host 2c/4 GB (L), 8 GB (M/W) | HELD: OQ-1. All thresholds stay parameters. |
| Whole product near-zero when idle | HELD: OQ-2. The idle ladder stays in the design; its timings are parameters. |
| CLI fallback where no tray host | HELD: OQ-3. |
| One machine, one region | HELD: OQ-4. See 2.4 for what must not be foreclosed. `[R:methodology capability_ladder]` |
| systemd user session required on Linux | HELD: OQ-5. |
| Project = git repo identity, local-only allowed | CHANGED, 2.4. |
| Browser to `*.localhost` for everything | CHANGED, 2.4. |
| `podman machine` adequate | KEPT, with the provider fixed, 2.3. |

## 2.2 Tray process model

- Rust, native backends, no timers, CLI and tray in one binary: unchanged.
- Lua (embedded) for policy and unit templates: unchanged; it is also the only
  glue language. No shell, no Python, no jq anywhere in the product or its
  install path. `[R:operator direction — Lua/Rust/Go, minimise bash and python, no jq]`
- **Progress surface.** The tray shows progress in exactly one non-interactive
  status line (step n of m or a percentage when known). No retry item and no
  per-step rows. The icon blushes progressively while containers are created,
  shows pups when done, and returns to plain on the first menu open.
  `[R:image-build-retry-and-tray-feedback-ruling]`
- **Degraded state.** The menu names the affected capability in a curated
  sentence. It does not show "which service and last log line"; raw log text
  never reaches the tray. `[R:operator-approval-and-ux-rulings — messages are curated]`
  `[R:forge-logs-die-with-the-forge]`
- **Retries.** A failed image pull or service start retries automatically in
  the background on exponential backoff a small number of times, then is
  declared failed. The user is never told that something worked on a later
  attempt. Agents receive a structured "busy, retry_after". `[R:image-build-retry-and-tray-feedback-ruling]`
- **Approvals.** Notifications plus a menu item, as designed. Each approval
  window is titled `<Agent>/<Project>/Launched at <date time>` and a grant is
  namespaced to that one forge instance; "allow for project" is removed until
  wider grants are ruled in. `[R:operator-approval-and-ux-rulings 2026-10-26]`
- **Cloud-cost actions** (dispatching CI, pushing or merging into an
  integration branch, opening a pull request, creating or refreshing a hosted
  resource, a deploy) require an OS-verified approval — Touch ID, Windows
  Hello, or on Linux a FIDO2 key or fingerprint — shown in a minimal dialog,
  and the approval is recorded on the commit or push. This is a new tray
  responsibility the blind design did not have. `[R:operator-approval-and-ux-rulings 2026-10-25]`
- **Sign-in** is started by the human from the tray only; no agent-run login
  flow exists. `[R:agents-never-start-a-sign-in]`
- **Storage root.** Everything the product owns on Linux lives under one
  findable root, `~/.tillandsias`; macOS and Windows use the single most
  contained equivalent. `[R:operator-approval-and-ux-rulings — storage]` `[R:media-studio-and-storage-direction]`

## 2.3 Substrate per platform

| | Linux | macOS | Windows |
|---|---|---|---|
| Userland | host user session | dedicated VM | dedicated WSL2 distro |
| How provided | host podman (a prerequisite, diagnosed not installed; never sudo, never layered) with a private store under `~/.tillandsias` `[R:no-sudo-no-layering-no-licence-without-operator]` `[R:operator-approval-and-ux-rulings — own podman store]` | `podman machine` named `tillandsias` on the **libkrun** provider `[R:media-studio-and-storage-direction 2026-10-28 — krunkit/libkrun approved]` | `podman machine` named `tillandsias` on the WSL provider; automount and interop off |
| Swap | tray refuses to start without disk swap and shows instructions | swap configured in the VM image | installer writes the swap and memory-reclaim keys; no prompt. The blind "we do not edit `.wslconfig`" is withdrawn for these keys only `[R:operator-approval-and-ux-rulings — swap is mandatory]` `[R:installer-is-for-end-users-no-prompts]` |
| Install | no prompts, no diagnostics printed; decisions made for the user | same | same; the OS's own elevation prompt for enabling WSL is the only interruption `[R:installer-is-for-end-users-no-prompts]` |
| Arch | amd64, arm64 | arm64; Intel is a separate obligation row, not implied | amd64; arm64 a separate row `[R:obligations-hold-per-platform]` |

Control, events, "stopped means" rows: unchanged.

Idle ladder: unchanged in shape. The 2-minute idle exit of socket-activated
services is an idle timeout on a blocked accept, not a poll. The 10-minute
substrate timer is one wakeup per region lifetime. Both are new cadences and
are listed for operator approval with their wakeups per hour (≤ 1).
`[R:polling-cadence-needs-operator-approval]`

## 2.4 Topology and services

Service table, networks, single `regiond` Go image: unchanged, except:

- **Forge token delivery.** `$FORGE_TOKEN` is no longer a podman secret (the
  default secret driver stores data unencrypted on disk). It is written to a
  tmpfs mount by the unit at start, or handed over the forge's own socket to
  `edge`. `[R:no-plaintext-credentials-at-rest]`
- **`vault`** keeps credentials in memory only, as designed. If the OS
  keychain cannot be opened, the stored sign-ins are wiped and the tray runs
  the sign-in flow again; there is no salvage step. `[R:vault-is-thrown-away-not-recovered]`
- **GitHub identity.** One sign-in, a GitHub App device flow started from the
  tray, is the only source of git identity; commits are authored as the human,
  agents are credited in `Co-Authored-By`. `[R:open-it-browser-direction — git identity 2026-10-13]`
- **Project.** `tillandsias open <path>` becomes `tillandsias open
  <owner>/<repo>`: a forge is launched from a hosted repository and a host
  path is refused. The "tray pushes a local-only repo into the mirror" path is
  removed. `[R:forges-launch-from-the-cloud]`
- **Forges per project.** PRJ-1 becomes "N forge instances per project". A
  second launch on the same project creates a new instance with its own
  working volume; both use the same `git` mirror repo, and each is told when
  the other has pushed. Networks stay per project; tokens and approvals are
  per instance. `[R:operator-approval-and-ux-rulings 2026-11-01]`
- **On-demand appliances.** A forge agent can ask, through `REGION_MCP`, for a
  sibling container (a web container for its app, a browser, a studio) to be
  started on its project network. The request is carried out by the substrate
  supervisor (a templated Quadlet unit instance started through the tray's
  control channel), so still no container holds the engine socket. Nothing of
  this kind auto-starts and none has a tray menu entry. `[R:operator-approval-and-ux-rulings 2026-11-02]`
- **Human access.** The agent runs in a terminal the human can watch. `edge`'s
  web terminal satisfies "visible, not headless"; whether a browser tab or a
  native terminal window is wanted is not ruled, so both the web terminal and
  "open in the system terminal" (`podman exec` through the substrate) are
  offered. `[R:forge-agents-visible-not-headless]`
  Project **previews** do not open in the user's default browser: they open in
  an isolated browser fully separate from the user's personal accounts (a
  container on Linux, Wayland only, receiving only the display socket; the
  native engine in an isolated guest on macOS/Windows). `[R:open-it-browser-direction]`
- **`log`.** Kept as an in-memory ring. journald inside the substrate is
  volatile (no disk journal). A forge can read only its own output, that of
  containers it started, and curated region-wide events; never a sibling's.
  Everything about a forge is dropped when it closes. No size cap is imposed
  on a live forge's logs. Agent session transcripts are not collected by
  `log`. `[R:forge-log-visibility-ruling]` `[R:forge-logs-die-with-the-forge]`
- **`llm`.** Budgets stay. User-facing wording says honestly that a metered
  provider bills the user's account even at zero cost and shows "free tier is
  enough" where true. `[R:operator-approval-and-ux-rulings 2026-10-26]`
- **`model` / local inference.** Optional as designed; starts with the
  smallest model and offers one tier larger at a time. A confined host helper
  for NPU or Metal (inference only, no internet, OS sandbox, one socket into
  the region) is a permitted exception to POD-1 where it exists; it is not
  required by this design. `[R:operator-approval-and-ux-rulings — small model first]` `[R:open-it-browser-direction — host helpers approved]`
- **Upstream relay policy.** A push to an integration branch or opening a pull
  request needs the OS-verified approval above; "human approval optional per
  project" is withdrawn for those. `[R:operator-approval-and-ux-rulings]`
- **Multi-host.** Nothing here forecloses it: service names are region names,
  not host paths; identity is minted by `vault`. `[R:methodology capability_ladder — never foreclose a higher rung]`

## 2.5 Lifecycle

- Cold start: unchanged, plus: a large first download is announced in a fully
  informed dialog with a disk bar; ordinary prompts show no raw sizes;
  durations are stated as honest ranges. `[R:operator-approval-and-ux-rulings]`
- Forge image content that is optional and network-flaky is installed in the
  background after the forge is usable, behind first-use shims that say "still
  installing". `[R:flaky-installs-go-background-direction]`
- Images are published only by an intentional release build, at most one
  cloud build per day; no build per commit. `[R:one-cloud-build-per-day]` `[R:cloud-builds-are-intentional-only]`
- Reset: three depths unchanged. The installer always performs the gentlest
  one and never asks; the deepest is a command-line flag only; uninstall asks
  exactly once behind a prominent irreversible-action warning that names the
  sign-ins. `[R:installer-is-for-end-users-no-prompts]` `[R:reset-is-the-baseline]`
- Updates: checks at tray start and region start, unchanged. On each stable
  release every reused component is fully upgraded or thrown away and
  recreated. `[R:durable-instructions-and-auto-upgrade-direction]`
- The region offers no push-triggered deploy for the product's own sites; a
  user project may opt in. `[R:no-auto-deploy-for-own-sites]`

## 2.6 Budgets

Unchanged as proposals; every number waits on OQ-1 and OQ-2. Each row is
reported per platform as its own pass or fail; no aggregate row.
`[R:obligations-hold-per-platform]`

## 2.7 Failure modes — rows that change

| Failure | Change |
|---|---|
| Service crash loop | curated sentence; no log line in the menu `[R: curated messages]` |
| Keychain locked / absent | unchanged (no plaintext fallback); if unopenable: wipe and sign in again `[R:vault-is-thrown-away-not-recovered]` |
| Egress denied | grant is per forge instance `[R: approvals namespaced to the forge instance]` |
| Disk full | also checked before a new working volume is created `[R:media-studio-and-storage-direction]` |
| No disk swap (Linux) | new row: tray refuses to start, shows instructions `[R: swap is mandatory]` |

## Languages

Rust (tray), Go (`regiond`), Lua (policy, templates). No bash, Python or jq.
Unchanged from the blind design; recorded because the direction requires it.
