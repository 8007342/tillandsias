<!-- @tombstone superseded:host-browser-mcp+browser-window-modes -->
<!-- @trace spec:host-browser-mcp -->
# host-chromium Specification

## Status

obsolete

## Purpose

Historical wrapper retained for traceability only. There is no host Chromium
any more: windows run in the engine container (1649-xqet), and the
`host-chromium-on-demand` spec this pointed at is retired too (order 2118-fk3w,
change `retire-host-chromium-on-demand`).

## Superseded By

- `openspec/specs/host-browser-mcp/spec.md`
- `browser-window-modes` (proposed by the `open-it-browser` change)

## Notes

- The prior `host-chromium` wrapper duplicated the release-time pinning,
  install location, and launch-detection contract now owned by
  `host-chromium-on-demand`.
- Keep trace links readable, but do not add new requirements here.
