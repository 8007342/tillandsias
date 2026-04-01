## Why

The default tracing-subscriber `.pretty()` formatter dumps accountability metadata (`accountability: true, category: "secrets", safety: "...", spec: "..."`) inline with the human message, then repeats it in the span context section. This makes logs hard to read and buries the safety/trace information that power users need to feel confident about how their data is handled.

## What Changes

- Create a custom `FormatEvent` implementation (`TillandsiasFormat`) that separates accountability metadata from regular fields
- Accountability events render as structured multi-line blocks: `[category] message`, indented `-> safety note`, indented `@trace spec:name URL`
- Regular events render as compact single-line: `TIMESTAMP LEVEL target: message {fields}`
- Target names are shortened for readability (`tillandsias_tray::secrets` → `secrets`)
- The `AccountabilityLayer` is removed — the custom formatter subsumes its rendering role
- The `--log-*` CLI flags continue to control per-module filter levels

## Capabilities

### New Capabilities

_None — this enhances the existing `runtime-logging` capability._

### Modified Capabilities

- `runtime-logging`: Log format changes from default pretty/full to a custom compact format with structured accountability rendering. Accountability events now always show safety notes and spec trace links as indented context lines instead of inline field dumps.

## Impact

- `src-tauri/src/log_format.rs` — new file, custom `FormatEvent`
- `src-tauri/src/logging.rs` — switch both file and stderr layers to `TillandsiasFormat`, remove `AccountabilityLayer` registration
- `src-tauri/src/main.rs` — add `mod log_format`
- `src-tauri/src/accountability.rs` — `spec_url()` stays (used by formatter), `AccountabilityLayer` becomes dead code
- Log file format and stderr format both change — any external log parsers would need updating
