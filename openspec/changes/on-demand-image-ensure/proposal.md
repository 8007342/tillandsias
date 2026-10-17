# Proposal — on-demand-image-ensure

Epic: `1776-ondm` (desired_release v0.5). Children: `1776-ch4m`, `1776-brk3`,
`1776-v1t4`, `1776-d5k2`, `1776-pr0g`. Related rows: `1770-z575` (cloudflare
login starts only Vault), `1771-4iw3` (forge-base pip step bounded),
`1775-8tx5` (same version string reuses the old forge image), `1744-xjfw`
(helper failure names its cause), `1502-utcy` (build error carries the log tail).

## Why

LIVE (operator, 2026-10-17): an agent launched in a forge asked the tray to
open a browser window and was told the `chromium-framework` image was
missing. The tray had never run `--init`, so only the images the forge launch
path ensures existed. The operator's direction: "container launch should
create missing images/containers on demand … make it robust: actual build
failures must NOT keep retrying and kill host resources."

SOURCE READ (2026-10-17, `crates/tillandsias-headless`):

- `main.rs` `ensure_image_exists` is already most of the mechanism: a
  per-image advisory flock (`resource_lock`, 900 s), a detached
  session-surviving helper (`--internal-ensure-image`), content identity
  (`image_identity` hashes the whole build context plus build args and the
  base image's digest), dependency recursion (`image_dependency`: forge →
  forge-base, chromium-framework → chromium-core), a downgrade guard
  (`version_guard`) and a named remedy on failure.
- The gap is COVERAGE, not mechanism. Three launch sites never call it:
  1. `browser_open.rs` `TrayBrowserContainers::start`'s Chromium branch
     builds `forwarder_spec` and the window spec from
     `tillandsias-chromium-framework:v<VERSION>` with `pull_never()` and no
     ensure. The WebKit branch (`start_webkit`, order 1656-tjv4) DOES ensure
     on first use, with a notice — the precedent this change generalises.
  2. `run_opencode_mode`'s ensure list is `proxy, router, git, inference,
     forge` — no `chromium-core`/`chromium-framework`. The forge is the
     process that later asks for a window. (`run_opencode_web_mode` and
     `run_status_check` list both; the lists have drifted four ways.)
  3. `vault_bootstrap.rs` `build_vault_image` is a second mechanism: identity
     and build, but no lock, no detach, no failure record. A third,
     `toolchain_exec.rs` `prepare`, keeps an in-process slot and "a failed
     build is reported once, then a later call retries".
- Nothing records a failed build. `IMAGE_BUILD_REMEDY` says "the build is
  retried on each launch". `InitBuildState` records `failed` for `--init`
  only, and `ensure_image_exists` never reads it. So a Containerfile that
  cannot build (a pinned package gone, a stalled index as in 1771-4iw3, a
  full disk) is rebuilt by every launch, every tray click and every MCP
  `browser.open`, each attempt holding the host for minutes.
- No free-space check precedes a build (`free_bytes_at` exists, used only to
  DESCRIBE a failure, order 1744-xjfw). No CPU/IO bound wraps `podman build`.
- `1775-8tx5` (measured on yoga): a rebuilt binary with the same version
  string launched the old forge image. The content identity SHOULD have
  caught it (the embedded asset manifest digest changes → runtime assets
  re-materialise → source digest changes → `LabelMismatch` → build). Why it
  did not is unmeasured; the launch prints nothing about which digest it
  decided on, so the live finding could not be diagnosed from its own
  output. This change makes every ensure decision print its verdict.

## What changes

- **One seam.** `ensure_image_exists` becomes the only way an image is built
  outside `--init`. `build_vault_image` and `toolchain_exec::prepare`
  delegate to it. Every container launch site names the images it needs in
  ONE table (`launch_images(site)`), checked by a guard against the
  `ContainerSpec::new("tillandsias-<name>:v…")` literals in the crate, so a
  new launch site cannot omit its image.
- **Chromium on demand.** `browser_open::start`'s Chromium branch ensures
  `chromium-framework` (and so `chromium-core`) before creating the window
  network, with the same first-use notice as WebKit. `run_opencode_mode`
  stops pre-building images the forge may never use: the forge's first
  `browser.open` builds them, visibly, exactly once.
- **A failed build is remembered.** A failure marker keyed on
  `(image_name, source_digest)` lives beside the init state
  (`$HOME/.cache/tillandsias/image-ensure-failures/<image>.json`). While a
  marker matches the current identity, every ensure refuses within seconds
  with `refused:image-ensure:<image>:build-failed-previously` naming the
  log, the first failure's cause (1744-xjfw's text) and the remedy. The
  marker clears itself when the inputs digest changes (a fix shipped) and on
  an explicit operator retry (`tillandsias --retry-image <name>`, the tray's
  "Retry build" item, or the forge's `prepare(force=true)`). A second
  attempt is allowed only after a backoff (10 min, then 1 h, then operator).
- **Bounded.** Before a build: free space on the podman store ≥ the image's
  declared need (a per-image constant: forge-base 8 GiB, chromium-core
  6 GiB, others 2 GiB) plus 1 GiB, else refuse
  `refused:image-ensure:<image>:disk:<free>/<need>` — no build, no marker.
  During a build: the podman child runs under `systemd-run --user --scope`
  with `CPUWeight=50 IOWeight=50 MemoryHigh=<60 % of MemTotal>` when
  systemd-run is present, else `nice -n 10`, so a floor-tier host stays
  usable. The 900 s lock wait stays; the build itself keeps 1771-4iw3's
  per-step budgets.
- **Visible.** Every on-demand build pushes `Preparing <label> (first use)`
  plus `step n/m` to the tray and to the requesting caller (forge MCP reply,
  CLI stderr), through the `parse_step` path `toolchain_exec` already has.
- **Diagnosable.** Each decision prints one line:
  `image-ensure <image> decided=<Skip|Retag|Build|Refused> digest=<sha256:…>
  present=<label digest or none> reason=<…>` (debug or not). This is the
  instrument 1775-8tx5 lacked.

## Not changed

- `--init` keeps building all of `INIT_IMAGES` as the explicit "prepare
  everything now" path; it also clears failure markers for the images it
  rebuilds successfully.
- No automatic `podman system reset`, no automatic image eviction (that is
  `podman-image-eviction`).
- The Containerfiles and image contents.
- macOS and Windows: the guest runs the same headless code; the trays' own
  "forge image present" probes are untouched here (follow-up if the guest
  path diverges).

## Risks

- The forge's first `browser.open` now waits for a chromium build
  (minutes). Mitigated by the progress reply and the notice; the alternative
  (pre-building in `run_opencode_mode`) is what the operator said freezes
  low-end hosts.
- A marker keyed on a digest that is itself wrong (1775-8tx5's unexplained
  reuse) could suppress a rebuild that would succeed. Mitigated by the
  operator retry path, which forces `ForceRebuild`, and by the decision
  line, which shows the digest the marker matched.
