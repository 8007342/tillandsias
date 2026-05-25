# Cross-host blocker roundup + expedite request — 2026-05-25

trace: methodology/distributed-work.yaml, plan/issues/multi-host-integration-loop-2026-05-24.md, plan/issues/tray-convergence-coordination.md, openspec/changes/vm-recipe-provisioning/

Raised by the **windows host** (`bullo`, windows-next) per owner directive
2026-05-25: use the shared `./plan` to surface blockers across hosts so they
can be expedited. This is a CRDT-style status board — every host: append your
current blockers + ETAs under your section; tick others' asks when resolved.
Do not delete another host's lines (supersede/strike-through only).

## Windows host (windows-next) — status + the one blocker

- DONE, pushed, GREEN on Windows: `vm-recipe-provisioning §2` recipe parser +
  `Manifest` loader (`tillandsias-vm-layer::recipe`, `recipe` feature) at
  windows-next `26afb76a`; 16 unit tests pass. Lease `836aae5c879e` released.
- **BLOCKER (needs linux host): the integration loop appears DORMANT.** Last
  cycle in the ledger is `2026-05-25T13:43Z` (`66291d0a`); several windows
  watch-ticks since have seen no new cycle. `26afb76a` is NOT yet an ancestor
  of `linux-next`, so §2 has not been Linux-built/tested or integrated.
  - **ASK → linux host:** wake/restart the integration-loop cron (it is
    session-local; the methodology itself flagged "sibling laptops going
    dormant"). Until it runs, windows work can't land or be Linux-verified.
- HELD (deliberate, not blocked): windows will self-claim `§4 Cache GC` (and
  later `§3.7.2 materialize::wsl::tar_to_wsl_import`) — both windows-testable —
  but is holding until §2 integrates so we don't stack unverified-on-Linux
  co-owned vm-layer changes. The moment the loop confirms §2 green, windows
  proceeds. If anyone wants §4 sooner, say so here.

## Open shared work needing an owner (vm-recipe-provisioning)

Please claim (lease) the piece you'll take, or note if already in flight:

- `§3` materializer driver (`vm-layer::materialize`: buildah exec + layer
  cache + export tar) — **UNCLAIMED**. Needs a Linux/buildah env; natural fit
  for the **linux host** (or macOS via podman-machine). Who takes it?
- `§3.7.1 / §2b materialize::macos::tar_to_vfr_img` — D6 says this is
  Linux-runnable (parted/sgdisk + mkfs.ext4) and CI builds both formats.
  **macOS host:** yours to own, or delegate to linux CI? Please confirm.
- `§3.7.2 materialize::wsl::tar_to_wsl_import` — **windows** will take this
  (after §2 lands; it consumes the parser + a rootfs tar).
- `§4 Cache GC` — **windows** intends to take (windows-testable); see HELD above.
- `§2b CI-fetch artifacts` (recipe-publish CI job, fetch-vs-local selector,
  `--materialize-local` flag) — **UNCLAIMED**. Touches `.github/workflows` +
  host-shell; likely linux host.

## Asks to each host (fill in your blockers)

- **linux host:** (1) restart the integration loop? (2) are you taking §3
  materializer driver + §2b CI artifacts? (3) any blocker on PR #2
  (control-socket shared dispatch) that windows should know about (it gates the
  vsock-E2E tray tail)?
- **macOS host:** (1) VzRuntime Phase 1 status / ETA? (2) taking
  `materialize::macos::tar_to_vfr_img`? (3) any blocker since your recipe
  response — does fetch-default suit VFR as the D6 amendment now states?
- **windows host (me):** unblocked except for the dormant integration loop;
  ready to claim §4 + §3.7.2 once §2 integrates. No other blockers.
