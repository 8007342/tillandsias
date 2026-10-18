# Proposal — tray-icon-state-machine

Packet: `1778-gct2` (desired_release v0.5). Related: `1776-pr0g` (the build
status line), `1443-bgbs` (Windows provisioning strip), `1420-v3zt` (macOS
menu-bar progress).

## Why

Operator ruling, 2026-10-17 (ruling 3 on 1776, relayed by macuahuitl-fedora):
the tray icon blushes progressively while containers are being created, like
a tillandsia before it has pups. When the work completes, the icon shows
pups. The first time the menu opens after that, the icon goes back to the
plain one. Each platform has its own icon set. With ruling 2 (one
non-interactive status line), this is the whole user-facing "something is
happening" surface.

The operator settled the meaning of "pups" the same day: pups mean the work
is done. The old meaning ("Pup = initializing", tray-icon-lifecycle) is
retired.

SOURCE READ (2026-10-18):

- `TrayIconState` (`tillandsias-core/src/genus.rs:239`) has six variants
  (Pup, Mature, Building, Blooming, Dried, Stopping). The spec says "exactly
  five". None of them blushes or progresses.
- The only icon-level blush is Windows' first-provision strip
  (`tray_phase_icon.rs` `paint_progress_strip`). macOS draws one fixed
  **template** image (`status_item.rs:205`), which macOS repaints in a single
  colour, and shows a blush only as menu-bar text. Linux swaps whole PNGs
  through `set_status`.
- Menu-open hooks: Linux has SNI `activate`/`context_menu` (they already turn
  Blooming into Mature) and dbusmenu `about_to_show`. macOS has no
  NSMenuDelegate. Windows opens its menu in `show_context_menu` and has no
  WM_INITMENUPOPUP handler.
- The macOS and Windows trays see container work only as the
  `VmStatusReply.last_event` string. No typed created/total progress reaches
  them.
- This is the `tray-icon-state-machine` follow-up that
  `2026-04-26-tray-progress-and-icon-states` deferred
  ("pup/green/blushing/bloom/withered + 10s revert"). It was never written.

## What changes

- **One pure reducer in core** (`tillandsias_core::tray_icon_state_machine`):
  the phases are Plain, Blushing(level 1..=BLUSH_LEVELS) and Pups. The events
  are work progress (done/total), work completed, work failed and menu
  opened. Each platform feeds it events and draws its phase. No platform
  holds its own copy of the rules.
- **Health states stay on top.** Dried (podman missing) and Stopping override
  the phase. Plain is today's Mature bud.
- **A per-platform icon set** rendered by `build.rs`:
  - Linux: SNI pixmaps.
  - macOS: menu-bar images at 18 pt @1x/@2x. The blushing and pups images
    are **non-template**, because a template image cannot carry colour.
    Plain may stay a template, so it follows the menu bar's appearance.
  - Windows: .ico at 16/20/24/32.
- **Menu-open wiring** on each platform drives the reducer's MenuOpened event.
- **Typed container-work progress** on the status reply for macOS and
  Windows, replacing parsing of `last_event`.
- **Artwork approval.** The operator sees and approves each platform's set
  before the change lands (tray-ux curation, `openspec/specs/tray-ux`).

## Not in this change

- The status line's text, which ruling 2 already approved.
- Any new menu row.
- The per-environment genus icons.
