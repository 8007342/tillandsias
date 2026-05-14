<!-- @tombstone superseded:runtime-logging+logging-accountability+external-logs-layer+runtime-diagnostics -->
<!-- @trace spec:logging-levels -->
# logging-levels Specification (Tombstone)

## Status

obsolete

## Deprecation Notice

This specification is a historical tombstone for the retired embedded
`external-logs.yaml` configuration model. The live behavior is now owned by:

- `runtime-logging`
- `logging-accountability`
- `external-logs-layer`
- `runtime-diagnostics`

There is no backwards-compatibility commitment. Keep this file for history only.

## Historical Context

The old model attempted to mix service-specific log configuration, syslog
routing, and CLI diagnostics into one spec. That architecture has been split
into narrower ownership domains and should not be treated as current behavior.

## Replacement References

- `openspec/specs/runtime-logging/spec.md`
- `openspec/specs/logging-accountability/spec.md`
- `openspec/specs/external-logs-layer/spec.md`
- `openspec/specs/runtime-diagnostics/spec.md`
