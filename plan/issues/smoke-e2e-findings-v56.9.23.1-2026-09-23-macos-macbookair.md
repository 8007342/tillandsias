# Smoke (macOS lane, 1367-irnh criterion 1b): v56.9.23.1: the menu bar shows the icon, not "T"

- run_start: 2026-09-23T22:39:16Z
- evidence_dir: session scratchpad (install log, menubar read, diagnose JSON)
- forge_lane_outcome: not run (the 1b check is scoped to the tray icon)
- signature_verification: cosign:could-not-run:not-attempted
- verdict: PASS (signatures unverified: not attempted). Criterion 1b holds on the INSTALLED app.

## Operator consent
The operator approved the installer path for this run (the installer swaps /Applications and launches the tray). Nothing was wiped.

## Method
Installed with the release's install-macos.sh (TILLANDSIAS_RELEASE_BASE pinned to v56.9.23.1): install_exit=0 and no ~/Applications fallback.
Then I read the menu bar through System Events accessibility, `title, description, help of menu bar items of menu bar 1` of the tray's process, with no screenshot.
PASS means an empty title (setImage + empty title). FAIL means the title reads "T".

## Result vs pre-fix control
| release | title | help | exe_path | in_app | launched by |
|---|---|---|---|---|---|
| v56.9.22.1 (control) | "T" | Tillandsias 56.9.22.1 | /Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray | true | launchd |
| v56.9.23.1 | "" (image) | Tillandsias 56.9.23.1 | /Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray | true | installer then launchd (PPID 1) |

Build: tillandsias-tray 56.9.23.1 (git 29f7c2df6). It carries 61e210e05 (the icon is embedded via NSImage initWithData).

## Not checked
- 2b (renders correctly in a light and a dark menu bar): this is VISUAL, and accessibility does not prove how it looks. It needs the person at the keyboard.
- The bare-binary /tmp arm (criterion 1): not run here.
- cosign.
