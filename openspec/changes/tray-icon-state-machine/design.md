# Design — tray-icon-state-machine

## Meaning (operator, 2026-10-17)

| Phase    | When                                   | Picture                               |
|----------|----------------------------------------|---------------------------------------|
| Plain    | at rest                                | ionantha bud (today's Mature)         |
| Blushing | containers are being created           | the bud blushing, deepening by level  |
| Pups     | the work completed                     | the plant with pups at its base       |

"Pup = initializing" is retired. App start shows Plain; Pups is never
shown at start.

## Reducer

`tillandsias_core::tray_icon_state_machine`, pure, with no I/O:

```
reduce(phase, event) -> phase

Plain    + Progress{done,total} -> Blushing(level(done,total))
Blushing + Progress{done,total} -> Blushing(max(old, level(done,total)))   monotonic
Pups     + Progress{done,total} -> Blushing(level(done,total))             new work
Blushing + Completed            -> Pups
Plain    + Completed            -> Plain     no work was seen: nothing to celebrate
Pups     + Completed            -> Pups
any      + Failed               -> Plain     a failure never shows pups
Pups     + MenuOpened           -> Plain     the first open acknowledges it
Blushing + MenuOpened           -> Blushing  work still running
Plain    + MenuOpened           -> Plain

level(done,total) = clamp(ceil(done * BLUSH_LEVELS / total), 1, BLUSH_LEVELS)
                    (total 0 -> 1: work has started, nothing counted yet)
```

`BLUSH_LEVELS = 4`. Levels only go up during one run, so a total that
grows mid-run (one more container) never makes the blush fade. The icon is
health first, then phase: Dried and Stopping override everything.
A failure shows no blush; the status line names the failure.

## Icon sets

`build.rs` gains a platform dimension: `(platform, phase, level)` maps to an
asset. The SVG sources stay under `assets/icons/ionantha/`:

- `bud.svg` (Plain).
- `blush-1..4.svg`: bud.svg with the leaf tips tinted along the
  tillandsias-progress-tty ramp (LEAF_RAMP → BLUSH_MID → TIP_BLUSH #E8637A).
- `pups.svg`: the rosette with two offsets at its base.

Per platform:

- **Linux:** 32x32 PNG pixmaps through `icon_pixmaps()`.
- **macOS:** 18 pt menu-bar images, @1x and @2x. Plain stays a template, so
  it follows light and dark menu bars. **Blushing and Pups must be
  non-template** (`setTemplate(false)`), because a template image is repainted
  in one colour and the blush would be lost. Their artwork needs a light/dark
  check.
- **Windows:** .ico at 16/20/24/32. The provisioning strip stays for
  first provisioning.

## Wiring

- **Linux:** `set_status` callers send Progress/Completed/Failed. SNI
  `activate`, SNI `context_menu` and dbusmenu `about_to_show(0)` send
  MenuOpened. `about_to_show`'s reply stays a single bool (the Wayland freeze,
  `tray/mod.rs:4046`).
- **macOS:** a new NSMenuDelegate whose `menuWillOpen:` sends MenuOpened.
  Status-reply polling sends progress.
- **Windows:** `show_context_menu` (or WM_INITMENUPOPUP) sends MenuOpened.
- **Progress source.** The guest counts the containers the current launch
  will create (total) and those created so far (done), and puts both on
  `VmStatusReply` as a typed field. The Linux tray reads the same counter
  in-process.

## Approval

The state machine is operator-approved (2026-10-17). The artwork is not
yet. Mock-ups of every platform's set go to the operator before the
wiring lands, and that approval is recorded as an event on 1778-gct2.
