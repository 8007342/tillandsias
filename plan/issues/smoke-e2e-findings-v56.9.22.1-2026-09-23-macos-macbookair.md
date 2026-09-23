# Smoke (macOS lane, NON-DESTRUCTIVE PARTIAL): v56.9.22.1 (channel: unstable), tray icon "T"

- run_start: 2026-09-23T06:46:15Z
- evidence_dir: scratchpad (downloaded tarball + diagnose JSON; not the target/smoke-e2e layout)
- forge_lane_outcome: not run (§4 is Linux/Podman; §1-§3 skipped, see Scope)
- signature_verification: cosign:could-not-run:not-attempted (integrity only: SHA256 a41638216e6b... matches SHA256SUMS-macos)
- verdict: FINDING. The published tray shows "T" for EVERY launch path, including the installed .app

## Scope: why this is partial
macbookair is an operator workstation. The destructive §1 (installer swaps /Applications and provisions a VM) and §2 (VM wipe) need that run's operator consent (1004-vsh2, 1281-pgit). A peer's request does not count as consent, and none was given. The coordinator's four questions are answerable without destroying anything.

## Coordinator questions (macuahuitl)
- (a) Menu bar: not observed directly (screencapture has no screen-recording permission on this host). The code path below is deterministic: "T".
- (b) `--diagnose --json` on the installed app: version 56.9.22.1, exe_path /Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray, in_app true.
- (c) Contents/Resources/tray-icon.png EXISTS in the installed bundle and in the published tarball: 151 B, 32x32 RGBA, 148 opaque px, byte-identical (cmp). The installed binary is byte-identical to the published one.
- (d) Launched by launchd (PPID 1), i.e. open -a / Finder / login, from /Applications. **This does not matter.** See below.

## Finding: the bundle candidate path is off by one directory
status_item.rs `status_icon_candidate_paths()` pops the exe name (-> Contents/MacOS), then calls .parent() TWICE (-> Tillandsias.app), then joins "Resources/tray-icon.png".
So the path resolves to /Applications/Tillandsias.app/Resources/tray-icon.png, which is ABSENT (verified with ls). The file really lives under Contents/Resources.
The only other candidate is the baked CARGO_MANIFEST_DIR: /Users/runner/work/tillandsias/tillandsias/crates/tillandsias-macos-tray/assets/tray-icon.png (from `strings` on the release binary), which exists on no user Mac.
So every CI-built tray falls back to "T", however it is launched. Dev builds show the plant only because the source tree exists locally. That explains why nobody on the fleet saw it.
Consequence for 1367-irnh: its context says the bundle candidate works for packaged runs. It does not; packaged runs are broken too. Embedding the PNG fixes both. Closure (1) should also launch the INSTALLED .app of a CI-built artifact, not only a bare binary in /tmp.
