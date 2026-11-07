# Proposal — tray-self-update

- **Order:** 2014-auup. **Design only:** no code lands with this change.
- **Builds on:** `hot-upgrade-live-stack` (1490-gttj: the binary handoff, ownership
  labels, adopt-on-start), `stable-upgrade-converge` (what happens to every reused
  component after an install), `fleet-durable-instructions` (`forge.reload` and the
  resume slot), 1918-vzsr (VZ save/restore, measured), and 2003-stbf (a stale lane
  says so). This change does not restate them. It adds how a stable release is
  found, verified and applied by the tray itself, and what running forges are told.

## Why

Operator, 2026-11-06, extending the 2026-11-03 auto-upgrade direction: restarting
forges for infra fixes is the important thing to fix now. Shutting the tray does
not stop forges, so the tray can update beneath them. Forges are told of new
facilities and may request a restart; a forge or the tray, per the update
definition, may request or require recreating a set of containers, from scratch
or from named snapshots, with their dnf upgrade steps. Live work is never lost: a
required restart waits for, or demands, a push first.

What exists today (surveyed 2026-11-06, trunk):

- **No self-updater on any platform.** A release reaches a host only when someone
  re-runs the curl or irm installer. `openspec/specs/update-system` is `obsolete`;
  the only live requirement is artifact selection per platform.
- **Integrity, not authenticity.** The installers check SHA256 against
  `SHA256SUMS*` from the same release. Nothing checks a signature: whoever can
  publish a release can publish its checksums.
- **Forge lifetime differs by platform.** On Linux a tray quit leaves forges
  running and the next tray adopts their lanes (1988-trkp). On macOS the VM runs
  inside the tray process (Virtualization.framework), so quitting the tray stops
  the VM and every forge in it; the installer's quit does the same. On Windows
  quit stops the WSL runtime.
- **Nothing tells a forge.** The lane MCP socket offers preview, studio, image,
  browser and cloudflare tools; nothing reports a version or restarts a forge.
  2003-stbf (report-only staleness) and `forge.reload` are designed, not built.

## What changes

1. The tray discovers a new **stable** release on events (start, menu open),
   rate-limited, with no new timer unless the operator approves one.
2. It verifies a **signature** over the release manifest with a key compiled into
   the running binary, then the SHA256 of each artifact, and refuses on any miss.
3. The release carries a **signed update manifest**: per component, the restart it
   needs (`none` | `optional` | `recommended` | `required`), containers to
   recreate (from scratch or from a named image snapshot) and dnf upgrade steps.
4. It applies per platform, keeping forges running (Linux, Windows) or frozen and
   resumed (macOS, VZ save/restore), then runs the converge pass.
5. Forges are **told** (`forge.update_status`), may ask for a restart
   (`forge.reload`), and a `required` restart waits for a push.
6. A failed new tray **rolls back** to the previous bundle; data is never rolled
   back and images keep their version tags.
7. Users can choose auto, notify-only or off, and postpone. The tray shows the state.

## Impact

macOS tray, Windows tray, Linux headless, the release workflow (manifest and
signature), the lane MCP surface, the guest boot path (macOS). User-facing tray
text is proposed here for operator review, not decided.
