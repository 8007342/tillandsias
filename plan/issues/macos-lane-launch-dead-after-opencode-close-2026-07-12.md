# P1: after closing the OpenCode lane, NO new lane can launch (instant PTY close) — existing lane unaffected

- Date: 2026-07-12
- Class: bug (P1, macOS lane lifecycle / guest substrate)
- discovered_by: operator attended m8 smoke (macOS arm64, osx-next
  `374cb0b8` tray, same session as
  `macos-opencode-first-attach-blank-lane-2026-07-12.md`)
- Related: `headless-restart-wedges-guest-podman-2026-07-12.md` (Windows:
  podman pause-process wedge after headless restart, recovery = `podman
  system migrate`), `headless-podman-events-watcher-rootless-wedge-2026-07-12.md`
  (Windows P1 root-caused to unit hardening — macOS unit templates audited
  clean this cycle, see note there), order 289 (lane teardown).

## Symptom / timeline (local time)

- ~15:30–15:39: OpenCode lane (second attach — first-attach blank-lane bug
  did NOT recur) ran a full in-forge meta-orchestration cycle. Operator
  closed OpenCode afterward.
- 15:39+: every subsequent lane launch fails instantly — Maintenance
  (which worked at 15:19) and OpenCode alike. Terminal opens, `screen
  /dev/ttys001` starts, and immediately: `[screen is terminating]` +
  `[tillandsias] session ended — you may close this window.` Zero lane
  output. Reproduced repeatedly by the operator.
- Meanwhile the ORIGINAL maintenance lane (ttys002, launched 15:19) stays
  fully interactive — live fish prompt verified via screen hardcopy at
  ~15:50 — and the tray still holds its PTY fd. Tray process healthy,
  0% CPU, no crash.

## Reading of the evidence

The wire, VM, tray, and existing lane are all fine; specifically the NEW
lane bring-up path dies guest-side within ~1s (tray allocates the PTY,
opens Terminal, then immediately tears down — consistent with the guest
reporting instant lane failure). Closing the OpenCode lane is the state
transition that precedes 100% of failures. Plausible mechanisms, in order:

1. Lane-close teardown (order 289 cleanup path) wedged guest podman —
   Windows hit two distinct flavors of exactly this class today; macOS
   recovery/diagnosis needs guest-side `podman ps -a` / `podman system
   migrate` equivalent evidence.
2. The headless's lane-launch handler crashed/wedged while its wire
   connection (used by the surviving lane's PTY relay) lives on.

## Idiomatic-layer forensic gap (file-worthy on its own)

With the tray owning the VM, there is NO way to run a guest-level probe:
`--exec-guest` boots/stops its own VM instance (would kill the live
session), tray stderr is discarded under `open`, and `--diagnose` is
static. Diagnosing THIS wedge live required the operator's surviving
forge prompt — pure luck. The control wire needs a host-invokable
guest-diagnostic verb that attaches to the RUNNING tray's VM (or the tray
needs a persistent lane-lifecycle log under `~/Library/Logs/tillandsias`).

## Repro

Fresh substrate → maintenance lane (works) → OpenCode lane → close
OpenCode → try launching any lane. Observed deterministic in one attended
session; rate unconfirmed.

## Recovery (CONFIRMED, same day)

Tray relaunch (operator launched the dist/ bundle) fully recovers: GitHub
Login succeeded first try, projects listed, OpenCode lane launched again.
So the wedge is guest/tray-session state, not persisted substrate damage.
Note: the relaunch REQUIRED a fresh GitHub Login — whether credential
re-entry after a VM restart is by-design (vault seal) or a persistence gap
belongs to `agent-login-flows-vault-2026-07-12.md` scope; observation
recorded in the 2026-07-12 macOS findings file.
