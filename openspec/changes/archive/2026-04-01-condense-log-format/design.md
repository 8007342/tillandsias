## Context

The logging system uses three `tracing-subscriber` layers:
1. **File layer** — default `Full` format, no ANSI, writes to `tillandsias.log`
2. **Stderr layer** — `.pretty()` format with ANSI, only when TTY detected
3. **AccountabilityLayer** — custom `Layer` impl that intercepts `accountability = true` events, renders curated output to stderr when `--log-*` flags are active

The `.pretty()` formatter produces verbose multi-line output that dumps all structured fields inline, including accountability metadata (`accountability: true, category: "secrets"`) that is meant for programmatic filtering, not human consumption. The same fields appear twice — on the event and on the enclosing span.

The `AccountabilityLayer` was built to work around this: when `--log-*` flags are active, it renders a curated view. But without those flags, accountability events are buried in field noise.

## Goals / Non-Goals

**Goals:**
- Accountability events always render with structured safety/trace info (not just with `--log-*` flags)
- Regular events are compact single-line
- Accountability metadata fields don't leak into the human-readable output
- Spec trace links are prominent and actionable (include GitHub search URLs)
- Target names are human-readable (`secrets` not `tillandsias_tray::secrets`)

**Non-Goals:**
- Changing which events are tagged as accountable (existing tagging is good)
- Adding new accountability categories beyond secrets/images/updates
- Modifying the `--log-*` CLI flags or `LogConfig` parsing
- Changing log file rotation or location

## Decisions

### Custom `FormatEvent` replaces both default formatters
**Decision**: Implement `TillandsiasFormat` as a single `FormatEvent<S, N>` type used by both file and stderr layers. ANSI is controlled by `writer.has_ansi_escapes()` at render time.

**Why not just switch to `.compact()`**: The compact formatter still dumps accountability fields inline. We need field-level control to separate accountability metadata from operational fields.

**Why not keep `AccountabilityLayer` alongside**: The custom formatter subsumes its rendering. Keeping both produces duplicate output for accountability events on stderr.

### Field classification via visitor pattern
**Decision**: A `Visit` implementation extracts fields into two buckets: accountability metadata (`accountability`, `category`, `safety`, `spec`) and regular operational fields (`container`, `error`, `tag`, etc.). Only operational fields appear in the `{key=val}` suffix.

### `AccountabilityLayer` removed from subscriber stack
**Decision**: Remove the `AccountabilityLayer::new()` construction and `.with(accountability_layer)` registration in `logging::init()`. Keep the module (`accountability.rs`) — `spec_url()` is used by the new formatter.

**`--log-*` flags still work**: They control filter levels via `build_filter()`, enabling info-level logging for specific modules that might otherwise be filtered. The flag machinery is unchanged.

## Risks / Trade-offs

**[Log format is a breaking change for external parsers]** → Tillandsias has no external log consumers. The log file is user-facing only. Low risk.

**[`AccountabilityLayer` code becomes partially dead]** → `spec_url()` and the test helpers remain live. The `AccountabilityLayer` struct and its `Layer` impl become unused. Accept the dead code rather than deleting infrastructure that may be useful later. Can clean up in a follow-up.

**[Multi-spec trace lines add vertical space]** → Events with `spec = "environment-runtime, secret-rotation"` emit one `@trace` line per spec. Acceptable — these are rare and the trace links are high-value.
