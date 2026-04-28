# Runtime diagnostics streaming

## Why

A multi-container/multi-distro architecture is difficult to triage when
something fails. Today users see only the host-side tray's tracing output
plus whatever the foreground forge prints. Errors inside the proxy, router,
git daemon, or inference distros are silent unless someone manually
`wsl.exe -d <distro> --exec tail -f <log>`.

A `--diagnostics` flag (superset of `--debug`) gives users a single command
that aggregates every relevant log into one prefixed stream they can grep.

## What changes

- Add `--diagnostics` CLI flag for `tillandsias <path>` attach mode.
- Implement on Windows: spawn `wsl.exe ... tail -F` per known log file, prefix
  each line with `[<distro>/<source>]`, multiplex into the calling terminal.
- Forge entrypoint mirrors `trace_lifecycle` output to `/tmp/forge-lifecycle.log`
  so the host's tail catches it.
- `--diagnostics` implies `--debug` (and propagates `TILLANDSIAS_DEBUG=1` into
  the forge so the lifecycle traces actually emit).
- Linux + macOS: stub returns a no-op handle and prints a notice. Phase 2
  implementations land in this same spec.

## Impact

- New spec capability: `runtime-diagnostics-stream`.
- New CLI flag, no breaking changes to existing flags.
- Drop-in observability for Windows users today; spec gates the Linux/macOS
  ports.
