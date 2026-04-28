# Runtime diagnostics stream — capability

## ADDED Requirements

### Requirement: --diagnostics flag aggregates every nested-environment log

Users invoking `tillandsias <path> --diagnostics` SHALL receive, in the calling
terminal, a multiplexed stream of every relevant log produced by the per-project
nested-runtime architecture (forge entrypoint, git daemon, proxy, router,
inference, etc.). Each line MUST be prefixed with a stable `[<distro-or-container>/<source>]`
token so users can grep by source.

#### Scenario: developer triages a startup failure

- **WHEN** the user runs `tillandsias ./my-project --diagnostics --opencode`
- **THEN** the calling terminal SHALL receive interleaved lines from:
  - the host-side tray/runner tracing (already present with `--debug`)
  - `tillandsias-git`'s git-daemon log
  - the forge entrypoint's lifecycle trace
  - any other service log listed in the implementation
- **AND** each line SHALL carry a `[<distro>/<source>]` prefix
- **AND** the user SHALL be able to `grep` by source token to isolate one
  service's output

### Requirement: --diagnostics implies --debug

`--diagnostics` SHALL be a strict superset of `--debug`. Setting `--diagnostics`
SHALL also set `--debug`-equivalent behaviour (verbose host tracing, lifecycle
emission inside the forge via `TILLANDSIAS_DEBUG=1`).

#### Scenario: --diagnostics alone activates debug tracing

- **WHEN** the user runs `tillandsias <path> --diagnostics --opencode` without `--debug`
- **THEN** host-side tracing SHALL emit at the same verbosity as `--debug`
- **AND** the forge SHALL receive `TILLANDSIAS_DEBUG=1` in its env so the
  entrypoint scripts emit `[lifecycle]` trace lines.

### Requirement: Per-platform implementations

The flag SHALL be implemented per-platform with shared semantics:

- **Windows (WSL backend)**: stream via `wsl.exe -d <distro> --exec tail -F <path>`
  on a curated list of log files. Implementation lives in `src-tauri/src/diagnostics.rs`.
- **Linux (podman backend)**: stream via `podman logs -f <container>` for each
  enclave service plus the forge. Implementation deferred to Phase 2.
- **macOS (podman-machine backend)**: same as Linux; `podman logs -f` works
  unchanged through the podman-machine remote. Implementation deferred to
  Phase 2.

Until Phase 2 lands on Linux/macOS, the non-Windows implementation SHALL print
a single notice and return a no-op handle so users on those platforms get a
clear "not yet implemented here" message instead of silent dead behaviour.

#### Scenario: Linux user passes --diagnostics today

- **WHEN** a Linux user runs `tillandsias <path> --diagnostics`
- **THEN** the runner SHALL print a one-line notice that streaming is
  Windows-only in this revision, with a pointer to this spec
- **AND** the rest of the attach SHALL proceed exactly as `--debug` would

### Requirement: Best-effort, never load-bearing

Diagnostics streaming SHALL NEVER block the attach flow on missing logs or
not-yet-running distros. Tail spawn failures emit one warning per source and
the attach continues. The handle SHALL clean up all spawned processes on Drop.

#### Scenario: A nested distro is missing at attach time

- **GIVEN** the user runs `tillandsias <path> --diagnostics` before `--init`
  has imported a particular distro (e.g. `tillandsias-inference`)
- **WHEN** the diagnostics handle attempts to spawn `wsl.exe -d <missing>
  --exec tail -F <path>`
- **THEN** the spawn failure SHALL emit at most one warning line for that
  source, AND the rest of the attach SHALL continue unaffected.

#### Scenario: Diagnostics handle drop kills tail processes

- **WHEN** the parent attach exits (Ctrl+C, normal completion, panic)
- **THEN** every `tail -F` (or `podman logs -f`) child process spawned by the
  diagnostics handle SHALL be terminated within the handle's Drop impl.

## Sources of Truth

- `cheatsheets/runtime/wsl-on-windows.md` — `wsl.exe --exec` semantics, distro lifecycle
- `cheatsheets/runtime/event-driven-monitoring.md` — `podman events`/`podman logs -f` patterns for the Linux/macOS port
