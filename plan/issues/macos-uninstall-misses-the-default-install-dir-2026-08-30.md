# macOS uninstall targets the fallback install dir, not the default one

Found 2026-08-30 on macos-m5-apple-tlatoanis-macbook-air while filing the
`.app.bak` housekeeping note from the v0.4.260830.5 release smoke. The
housekeeping item is real but minor; this one sat behind it and is not.

## The defect

`scripts/install-macos.sh:131-138` picks the install dir:

    INSTALL_DIR="/Applications"
    if ! [[ -w "$INSTALL_DIR" ]]; then
        INSTALL_DIR="$HOME/Applications"

So `/Applications` is the PREFERRED target and `$HOME/Applications` is only a
fallback for a non-writable `/Applications`. On a personal Mac — an admin
account, the common case — the app lands in `/Applications`.

`scripts/uninstall.sh:238` removes exactly one path:

    rm -rf "$HOME/Applications/Tillandsias.app"

It never touches `/Applications/Tillandsias.app`. So on the DEFAULT install
path, **uninstall leaves the application installed**. It removes the
LaunchAgent plist beside it, so the result is worse than a no-op: the app
stays in /Applications while the thing that would have launched it is gone.

Measured on this host: install landed at `/Applications/Tillandsias.app`
(30 MB); `$HOME/Applications/Tillandsias.app` does not exist at all, so the
uninstall line is a guaranteed miss here.

## Why it survived

The uninstaller is overwhelmingly linux-shaped (`.desktop` files, hicolor
icons, `update-desktop-database`, `userdel`), and the macOS block is four
lines appended to it. A linux lane cannot exercise either path, and a macOS
lane only notices if someone actually uninstalls — which the release smoke
does not do. Same sole-detector shape as
`methodology/distributed-work.yaml` → `the_sole_detector_surface_is_wider_than_cfg_code`.

## The `.app.bak` item, corrected

Worth stating precisely, because the first report of this (mine, to the
coordinator) overstated it. `install-macos.sh:154-158`:

    if [[ -d "$DEST" ]]; then
        BACKUP="${DEST}.bak"
        rm -rf "$BACKUP"
        mv "$DEST" "$BACKUP"

Line 156 deletes the previous backup, so it does NOT accumulate across
installs — exactly one `.bak` exists at any time, bounded at ~30 MB. Two
things are true about it and neither is growth:

1. It is never removed on success, so one stale 30 MB copy persists
   indefinitely after the last install.
2. Nothing reads it. There is no rollback path — `BACKUP` appears on line
   155 and nowhere else in the repo. It is a backup that cannot be restored
   from, except by hand.

And it inherits the defect above: `uninstall.sh` does not remove
`/Applications/Tillandsias.app.bak` either, so a user who installs then
uninstalls is left with ~60 MB in /Applications and no way to notice.

## Fix shape

Uninstall should remove the app from BOTH candidate dirs, plus the `.bak`
sibling of each — deriving them from the same precedence the installer uses
rather than hardcoding one:

    for d in "/Applications" "$HOME/Applications"; do
        rm -rf "$d/Tillandsias.app" "$d/Tillandsias.app.bak"
    done

Separately decide whether the `.bak` should be dropped after a verified
launch, or kept deliberately and documented as a manual rollback (in which
case the installer should say where it is, and uninstall should still take
it).

## Verification when drained

A fixture can pin this without a real install: create both candidate dirs
with a stub `Tillandsias.app` plus `.bak`, run the uninstaller, assert both
dirs are empty. That runs on any platform, so the fix does not stay
darwin-only detectable the way the defect was.
