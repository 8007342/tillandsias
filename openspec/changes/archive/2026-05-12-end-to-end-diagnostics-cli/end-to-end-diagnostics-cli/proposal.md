# end-to-end-diagnostics-cli Change Proposal

## Why

Current initialization and debugging workflows lack visibility into container lifecycle and health. Users running `tillandsias --init` cannot verify all images build (including new browser isolation containers), and there's no straightforward way to inspect live logs for troubleshooting. We need end-to-end observability: a predictable initialization flow that builds all containers, plus a diagnostic mode that streams container logs in real time for quick troubleshooting.

## What Changes

- **`tillandsias --init --debug`** now builds proxy, forge, git, inference, **browser-core**, and **browser-framework** containers
- **`tillandsias --diagnostics`** new flag: streams live `podman logs -f` output from all running Tillandsias containers to terminal for real-time troubleshooting
- **Observable convergence**: All implementation paths annotated with `@trace spec:<name>` and observability events logged with `spec=` attributes (linkable to specs)
- **Cheatsheet-driven implementation**: All container/logging behavior informed by provenance-cited cheatsheets (e.g., `docs/cheatsheets/podman-logging.md`, `docs/cheatsheets/container-lifecycle.md`)
- **Spec synchronization**: Implementation and specs converge monotonically via `@trace` links and delta specs with provenance sections

## Capabilities

### New Capabilities

- **`cli-diagnostics`**: The `--diagnostics` command-line flag that aggregates and streams live container logs from all running Tillandsias-managed containers (proxy, forge, git, inference, browser-core, browser-framework) to the calling terminal, with clear source labels and timestamp ordering for troubleshooting.

- **`observability-convergence`**: Structured observability pattern: all code paths emit events with `spec=` and `cheatsheet=` attributes, linked to source specs and cheatsheets via `@trace` annotations. Enables bidirectional traceability: code → spec → cheatsheet and vice versa.

### Modified Capabilities

- **`init-command`**: Enhanced to build all enclave images (proxy, forge, git, inference) plus **new browser isolation images** (browser-core, browser-framework). `--debug` flag enables verbose logging and skips timeouts to allow container inspection.

## Impact

- **Code**: `src-tauri/src/cli.rs` (add --diagnostics flag), `src-tauri/src/handlers.rs` (diagnostics handler + podman log aggregation), `src-tauri/src/init.rs` (add browser image builds)
- **Specs**: New specs for `cli-diagnostics` and `observability-convergence`; delta specs for modified `init-command`
- **Cheatsheets**: New `docs/cheatsheets/podman-logging.md` (container log inspection patterns) and `docs/cheatsheets/container-lifecycle.md` (container state machine), both with provenance citations
- **Tracing**: `@trace spec:cli-diagnostics`, `@trace spec:observability-convergence`, `@trace spec:init-command` throughout implementation
- **Dependencies**: None new; uses existing podman, CLI structures
