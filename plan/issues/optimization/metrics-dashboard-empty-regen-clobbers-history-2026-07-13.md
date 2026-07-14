# metrics-dashboard.md regenerates from the LOCAL telemetry store and clobbers committed history when that store is empty

- Date: 2026-07-13
- Class: optimization (tooling data-loss hazard)
- Filed by: macos-osx-next meta-orchestration cycle 2026-07-13T22:43Z
- Pickup: linux

## Observed

During the macOS e2e cycle, `plan/metrics-dashboard.md` appeared modified
with EMPTY chart data (`x-axis "Builds" 1 -> 1`, `line []`), silently
discarding the 4 committed build datapoints from Linux hosts. The regen ran
as a side effect of this host's runs (guest builds log telemetry to the
GUEST's /tmp/tillandsias/image-build-events.jsonl — `[tillandsias]
image-build telemetry: /tmp/tillandsias/image-build-events.jsonl` in the
init log — so the HOST-side store on macOS is empty). Committing the file
as-is would have erased the history; this cycle reverted it.

## Fix shape

The dashboard generator must refuse to regenerate (or no-op with a notice)
when the local telemetry store has fewer datapoints than the committed
dashboard — regeneration should be monotonic append, never silent shrink.
Alternatively, aggregate per-host series instead of overwriting a single
global series. Pin with a fixture: regen against an empty store leaves an
existing dashboard byte-identical.
