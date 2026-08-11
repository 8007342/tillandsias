# Windows tray ships a guest binary older than its own checkout (staged asset 0.4.260809.2 vs workspace 0.4.260810.1)

- Order: 689-gipe
- Class: enhancement
- Filed: 2026-08-11, windows host, branch `windows-next`
- Found by: meta-orchestration cycle 2 while draining order 154

## Observation

`cargo test -p tillandsias-windows-tray` is RED on this host at HEAD, before
any local edit:

```
test wsl_lifecycle::tests::embedded_guest_headless_matches_workspace_version ... FAILED
embedded x86_64 guest headless does not contain workspace version 0.4.260810.1 —
stale staged binary; re-run scripts/build-guest-binaries.sh then scripts/build-windows-tray.ps1
```

Confirmed pre-existing by stashing the cycle's edits and re-running at a clean
tree — same failure, so it is not a regression from order 154's slice.

The staged asset is a real binary, not the sanctioned zero-byte placeholder:

```
crates/tillandsias-windows-tray/assets/tillandsias-headless-x86_64-unknown-linux-musl
  13731128 bytes, mtime 2026-08-09 02:22
  highest version string: 0.4.260809.2      (workspace VERSION: 0.4.260810.1)
```

`0.4.260809.2` is the PUBLISHED release the peke field host was running when
627-sgtt was filed. The aarch64 slot is correctly zero-byte.

## Why it matters beyond a red test

The test is behaving exactly as designed — this is a true positive, and the
fix is to restage the asset, not to soften the assertion. Two consequences
follow from the stale asset itself:

1. **Any tray built on this host embeds a guest older than the checkout it was
   built from.** The embed is the injection source for a fresh provision, so a
   cold provision from a locally built tray installs 0.4.260809.2 while the
   tray reports the checkout's version. This is precisely the "registered
   distro version skew produces a false parity result" failure that order 350's
   first exit criterion exists to catch, and it is live on this host now.

2. **It falsifies an inference this host recorded earlier today.** Cycle 1
   promoted 627-sgtt to `completed` citing, among other things,
   `guest_version == host tray version` as showing "the rebuilt binary IS
   deployed". That does not follow. The tray's embedded guest is 0.4.260809.2,
   so nothing this cycle's tray build could inject would have produced the
   0.4.260810.1 the guest reports; that binary (in-VM, mtime 2026-08-09 21:32)
   predates the rebuild. `reconcile_adopted_guest` returns early on a version
   match, which is the exact trap 627-sgtt's own `next_action` warned about.
   A correcting note is appended to the packet. The packet's other criteria
   (login reaches the token prompt, no process in state T, the named workspace
   test) stand on their own evidence and are unaffected.

## Smallest next action

Restage the asset on a host that can cross-build musl:
`scripts/build-guest-binaries.sh`, then `scripts/build-windows-tray.ps1`, and
confirm `embedded_guest_headless_matches_workspace_version` goes green. Not
done in this cycle: the musl cross-build does not fit the recurring-loop
budget, and staging a 13 MB binary is a commit this host should not make
blind.

## Verifiable closure

`cargo test -p tillandsias-windows-tray embedded_guest_headless_matches_workspace_version`
exits 0 with a non-empty x86_64 asset — i.e. green because the asset is
current, not because it was emptied. The existing test already distinguishes
those two cases (a zero-byte slot passes trivially by design), so the closure
check must also assert the asset is non-empty.

## Related

- 683-g7p6 `forge-rebuild-silently-uses-stale-bundled-assets-not-live-source`
  — same shape (a build consuming stale bundled assets rather than live
  source), different lane. Worth reading together; not a duplicate.
- 350 `windows-forge-config-trust-live-parity` — its criterion 1 (record
  identity before behavior evidence) is the guard against exactly this skew.
- 627-sgtt — the corrected inference above.
