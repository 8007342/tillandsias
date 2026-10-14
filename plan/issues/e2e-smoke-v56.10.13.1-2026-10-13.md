# E2E smoke v56.10.13.1 — linux, macos, windows — PASS (2026-10-13)

Per-platform record of the release smoke for tag v56.10.13.1, written as the
evidence `scripts/promote-stable.sh` reads before a stable promotion.

## Verdicts

| Platform | Verdict | Host | Run |
|---|---|---|---|
| linux | PASS v56.10.13.1 | lenovinha-silverblue | run v56.10.13.1-20261013235228, project=03a46e1f3, sealed substrate |
| macos | PASS v56.10.13.1 | tlatoanis-macbook-air | Mac smoke against trunk 175144b37 / f50d6e56d |
| windows | PASS v56.10.13.1 | yolanda-windows | curl install + tray + OpenCode lane, below |

## windows (yolanda-windows) — PASS v56.10.13.1

- Install: the documented `irm | iex` one-liner on the unstable channel. The
  installer printed its preview-build notice, added the Start menu entry and
  started the tray.
- Tray: reached Ready with the existing GitHub sign-in kept (no re-login).
- Lane: `tillandsias-headless --cloud 8007342/tillandsias.org --opencode`
  inside the `tillandsias` WSL guest (the path the tray launches) cloned the
  project, seeded branch `main`, and answered the prompt with `READY`;
  `lane-rc=0`. The stack cleanup afterwards kept the application-lifetime
  services and stopped only the lane-scoped inference container.
- Accel envelope: a second lane printed `TILLANDSIAS_ACCEL_ENVELOPE` from inside
  the forge: `accel_class=cpu-only`, `accel_side=wsl2-guest`,
  `accel_gpu=present-unusable` (`engine-missing_no-vulkan-loader`),
  `accel_decode_floor_b=-`. The envelope reaches the forge; CPU-only is this
  host's known state, not a regression.
- Not a PASS condition, recorded for completeness: a host-side
  `tillandsias.exe --opencode` invocation against the same project refused
  with "Project not found" (rc 1) before the in-guest lane was used. The
  tray's own launch path is the in-guest one, which passed.

## Provenance

- The windows row is yolanda-windows's own smoke (2026-10-13, v56.10.13.1).
- The linux and macos rows were relayed by the coordinator
  (macuahuitl-fedora) on 2026-10-13 from lenovinha-silverblue's and the Mac's
  runs; yolanda-windows did not observe them directly.
