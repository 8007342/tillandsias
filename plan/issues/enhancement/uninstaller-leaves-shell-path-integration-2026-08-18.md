# Freshness audit: the uninstaller left every shell exporting a deleted PATH

- **Date**: 2026-08-18
- **Auditor**: windows (yolanda), MO cycle `windows-yolanda-opus5-20260818t1119z`
- **Class**: `enhancement`
- **Component**: `scripts/uninstall.sh` (top unstamped, `freshness-next: scripts/uninstall.sh source=unstamped seed=20260818`)
- **Disposition**: **updated**
- **Coverage at audit time**: `freshness-coverage: 2.9% (39/1367 delta=+0)`

## The audit question

*Last properly looked at and confirmed still meaningful, useful, efficient,
sound, and complete?*

**Meaningful and useful**: yes. It is the shipped uninstaller and it is
non-trivial — six XDG paths on Linux that collapse onto one on macOS.

**Sound**: yes, and carefully so. The `804-bpke` seams
(`TILLANDSIAS_UNINSTALL_FAKE_UNAME`, `TILLANDSIAS_UNINSTALL_INSTALL_DIR`) exist
so the macOS arm is testable without deleting a real installed binary, and the
`804-wfcu` comment documents the `userdel -r` / `rm -rf $SERVICE_HOME` overlap
and sizes the model cache before destroying it.

**Complete**: **no.** That is the finding.

## The finding

`scripts/install.sh` writes shell PATH integration in five places:

| written by install.sh | removed by uninstall.sh (before) |
|---|---|
| marked block in `~/.profile` | no |
| marked block in `~/.bashrc` | no |
| marked block in `~/.zprofile` (zsh only) | no |
| marked block in `~/.zshrc` (zsh only) | no |
| whole file `~/.config/fish/conf.d/tillandsias.fish` | no |

So an uninstall deleted `$INSTALL_DIR` and left every one of the user's shells
still exporting a PATH entry pointing at it, plus an orphan fish config file.

The part worth naming: `install.sh` already brackets the block with
`PATH_MARKER_BEGIN` / `PATH_MARKER_END`. **Those markers existed only for
install-side idempotency** — `append_posix_path_block` returns early when BEGIN
is present — **and nothing ever used them for removal.** An installer that
leaves a marker and an uninstaller that ignores it is a half-finished
handshake, not a design decision.

## What changed

Symmetric removal in `scripts/uninstall.sh`, plus
`scripts/test-uninstall-path-block.sh` (5/5 green).

Two choices worth recording:

1. **`awk` into a temp file, not `sed -i`.** This edits user dotfiles that
   predate the install and will outlive it. `sed -i` takes a mandatory backup
   suffix on macOS and not on GNU, so the portable spelling is a temp file we
   control. A failed rewrite deletes the temp and leaves the original
   untouched — a truncated `.bashrc` is a far worse outcome than a surviving
   PATH block.
2. **The fish file is removed only if it is ours.** If the user added their own
   lines to `tillandsias.fish`, the file stays and only the marked block goes.

## What the tests assert, and why those

The dangerous failure here is not "the block survived" — it is "the user lost
something else". So the fixture asserts, in order of what would hurt:

- lines **before and after** the block survive byte-identical
- a file with **no marker** is not modified at all (`cmp`)
- a **missing** file is a no-op, so an uninstall does not fail because the user
  never had a `.zshrc`
- **two** blocks (a double install) are both removed, since removing only the
  first would leave a live PATH export and report success
- an **unterminated** block preserves everything before it

It also pins the marker strings in `install.sh` and `uninstall.sh` against each
other: if they drift, the uninstaller searches for a marker nobody writes and
silently removes nothing, which is exactly the state this audit found.

## Honest limits

- **Mode preservation is implemented but not asserted.** The removal calls
  `chmod --reference` so a `0600` dotfile does not come back `0644`, but this
  audit ran on Windows/MSYS where `chmod 600` does not stick, so the fixture
  cannot test it. A Linux or macOS host can add that assertion cheaply.
- **The unterminated-block case still eats the remainder of the file.** `awk`
  cannot know where an unterminated span ends. The test pins that preceding
  content survives so the damage is visible rather than silent; making it
  refuse outright would be a defensible alternative and is not done here.
- Only the `.sh` uninstaller was audited. The Windows uninstall path is the
  tray's own and was not in scope.

## Also re-checked

This cycle added a new derived artifact (`capabilities.json`, order 808-43mw)
at `$HOME/.cache/tillandsias/`. Already covered: `CACHE_DIR` is removed under
`--wipe`. No change needed. The `TILLANDSIAS_CACHE_DIR` override and the
`temp_dir()` fallback are deliberately not covered — one is an explicit
operator choice and the other is self-cleaning.
