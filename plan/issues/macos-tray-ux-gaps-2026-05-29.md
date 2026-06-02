# macOS tray UX gaps observed during user-attended smoke — 2026-05-29

trace: openspec/specs/macos-native-tray/spec.md (the contract these violate)
       openspec/specs/tray-icon-lifecycle/spec.md
       openspec/specs/tray-menu/spec.md
       plan/issues/macos-build-findings-2026-05-29.md (autonomous smoke reported "ok" on both runs)
       plan/issues/osx-next-work-queue-2026-05-25.md (the active macOS work queue)
       plan/steps/20-macos-tray-v0_0_1.md

## Why this file exists

`/build-macos-tray` ran twice on 2026-05-29 and both runs reported
SECTION_KIND=ok: codesign verified, entitlement present, `--diagnose --json`
emitted the 13-key schema, detached launch survived 3s, SIGTERM round-trip
clean. **The autonomous smoke is not catching real UX regressions** that
become obvious the moment the bundle is launched interactively.

This file is the durable list of those regressions so they are picked up by
the next hourly `/build-macos-tray` iteration and by future
`/test-e2e-macos-tray` runs (skill TBD — see "Open questions" below).
Each gap names the spec it violates so the implementer has a single place to
check the contract.

## SECTION_KIND key

- `ux-regression` — visible bug in installed `.app`; blocks v0.0.1 user-smoke.
- `runtime-failure` — log/error surfaced to the user during normal use.

---

### gap-1 — Status item shows the letter "T" instead of a tray icon

- SECTION_KIND: ux-regression
- observed: 2026-05-29, latest installed bundle at `~/Applications/Tillandsias.app` (post-`/build-macos-tray` run `20260529T193710Z`, version `0.2.260528.1`, head `5e331872`)
- expected (`openspec/specs/macos-native-tray/spec.md:49-52`): the user SHALL see the tillandsias icon in the menu bar within 500ms of launch
- actual: the `NSStatusItem` button displays the bare letter `T` — no template image, no icon asset
- likely cause (to verify, not assumed): `NSStatusItem.button.image` is not being assigned, so AppKit is falling back to `button.title = "T"` (or the equivalent first-letter fallback). The icon asset may be missing from the bundle's `Resources/`, or the asset is present but the load path is wrong, or the `NSImage` is not being templated for menu-bar tinting.
- verification to add to `/test-e2e-macos-tray` once it exists: assert `defaults read ~/Applications/Tillandsias.app/Contents/Info.plist` shows the icon reference AND `find ~/Applications/Tillandsias.app/Contents/Resources -name '*.png' -o -name '*.icns'` is non-empty AND a screenshot of the menu bar shows pixels matching the expected template (not the glyph "T")

### gap-2 — Menu structure does not match the macos-native-tray parity contract

- SECTION_KIND: ux-regression
- observed: 2026-05-29, same bundle as gap-1
- expected (`openspec/specs/macos-native-tray/spec.md:64-88`): menu top-level groups SHALL match `status_text`, `projects`, `agents`, `observatorium` (disabled with "v2 — terminal-only in v1"), `opencode_web` (disabled, same tooltip), `github_login`. The menu SHALL be built from a `host_shell::MenuStructure` snapshot.
- actual: user reports "a bunch of incorrect menus" — exact divergence not yet captured. Need a screenshot or item-by-item dump before the next implementation pass.
- open data-collection task: next time the user launches the app, capture either (a) a screenshot of the open menu, or (b) `lldb` print of the NSMenu items via `po [[statusItem menu] itemArray]`. Once the actual menu is captured, this gap can be split into one sub-gap per missing/extra/wrong-state item.
- likely cause hypotheses (none confirmed): (i) the macOS menu builder is not consuming the latest `MenuStructure` shape from `tillandsias-host-shell` after a recent shell refactor; (ii) the v2-disabled items are missing the disabled state or the tooltip; (iii) hardcoded macOS-specific menu items leaked in during an early platform-port phase and were never reconciled with the parity spec.
- verification to add to `/test-e2e-macos-tray`: drive the menu via AppleScript / Accessibility API, dump the item titles + `isEnabled`, assert the set matches the parity contract

### gap-3 — "Failed to fetch recipe" surfaces to the user during normal launch

- SECTION_KIND: runtime-failure
- observed: 2026-05-29, same bundle as gap-1
- expected (`openspec/specs/macos-native-tray/spec.md:95-117` + spec:vm-provisioning-lifecycle): first-run path SHALL fetch the rootfs/manifest pinned in `images/vm/manifest.toml` (currently SHA `6859a7bc...9730bee` on release `v0.2.260526.1` per `plan/issues/osx-next-work-queue-2026-05-25.md:9-16`) and proceed toward VZ guest boot. Errors that *do* occur should be diagnosable, not opaque.
- actual: the tray surfaces "failed to fetch recipe" without further detail (URL? status code? SHA mismatch? offline?). This contradicts the autonomous-smoke claim that "auto-boot worker engages on launch and immediately enters the recipe-artifact-fetch path — this is m5 working as designed" from `plan/issues/macos-build-findings-2026-05-29.md:42`. The autonomous smoke SIGTERMs at 3s before the fetch completes, so it cannot tell the difference between "fetch in progress" and "fetch will fail".
- data needed before fix: the exact error string the user sees, the stderr log line that emitted it, the value of `RECIPE_RELEASE_TAG` baked into this binary (the diagnose JSON reports `release_tag=v0.2.260526.1`, `manifest_pin_aarch64_img=6859a7bcc4a9` per today's findings), and whether the release asset is reachable from this host (`curl -I` against the pinned URL)
- known related context:
  - `RECIPE_RELEASE_TAG` is hardcoded in the tray pending `Manifest::release_tag()` accessor (work-queue item 1 under "Non-blocking nice-to-haves")
  - `bytes-level proven at commit 303a5c24 (iter 38)` per work-queue line 17-19 — the proof was against the release asset at that time, not necessarily current network/disk state
- likely cause hypotheses (none confirmed): (i) network/DNS issue local to this run; (ii) release asset moved/renamed since the bytes-level proof; (iii) SHA mismatch after a recipe republish that hasn't been pinned in `manifest.toml`; (iv) macOS sandbox/entitlement blocking the outbound fetch despite the `com.apple.security.virtualization` entitlement being present.
- verification to add to `/test-e2e-macos-tray`: launch installed bundle with `--no-auto-boot` (does not exist yet — see findings file iteration note), OR launch + wait + dump stderr, assert no "failed to fetch" line, assert `--diagnose --json` shows `provisioned=true` after a successful run

---

## What the next iteration should do

Pick one gap per iteration. For each:

1. Reproduce the gap against the current `osx-next` HEAD (the bug may already be fixed — the install on the user's host is from `5e331872`).
2. Capture the missing data named in the gap (screenshot for gap-1/2, exact stderr line for gap-3).
3. If reproducible, file fresh evidence as a section in the current day's `plan/issues/macos-build-findings-<DATE>.md` under SECTION_KIND=ux-regression (or runtime-failure).
4. Implement the fix touching the spec-named files only; keep the change small enough to land in one commit.
5. After the fix, append a `gap-N status: resolved at <SHA>` line to this file, do NOT delete the gap section (the history of what was broken is itself a litmus the e2e suite should retain).

## Open questions

- **/test-e2e-macos-tray skill does not exist.** The user asked for a daily e2e loop on this skill. Options: (a) scaffold the skill (mirrors `/build-macos-tray` but adds menu-bar screenshot, AX menu dump, stderr tail), (b) skip the daily loop until the skill exists, (c) inline the e2e flow as a one-off prompt the daily cron runs. Deferred to user.
- **No `--no-auto-boot` flag on the tray binary.** Without it, every smoke run starts the recipe-fetch path. Adding the flag would let both the autonomous-smoke and the future e2e suite test menu/icon without the recipe variable. Flagged in today's findings file (`macos-build-findings-2026-05-29.md:42`).
- **Menu divergence is undocumented.** Need a screenshot or item dump from the user's host before gap-2 can be split into actionable sub-tasks.
