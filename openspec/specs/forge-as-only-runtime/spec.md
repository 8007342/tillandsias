<!-- @trace spec:forge-as-only-runtime -->
# forge-as-only-runtime Specification

## Identity

- **Name**: forge-as-only-runtime
- **Status**: current
- **Owner**: linux-runtime

## Authority

Every coding agent, maintenance shell, and runtime utility executes inside the
project's forge container; there is no host-side execution surface.

The host's role is limited to:

1. Operating the tray / headless orchestrator (a Tillandsias-internal process).
2. Spawning the user's default terminal emulator as a TTY host for an
   interactive `podman run -it`.
3. Managing podman itself (process supervision, image builds, secrets).

Every developer-facing tool — `claude`, `codex`, `opencode`, `opencode serve`
(OpenCode Web), and the maintenance shell — runs **inside** the forge. The
host never invokes those binaries directly. The forge image is the only place
where agent CLIs live, and the idiomatic podman layer
(`crates/tillandsias-podman`) is the only path that launches them. Direct CLI
flags (`--codex`, `--claude`, `--bash`, `--opencode`) attach the current
terminal to the forge; tray launches spawn a host terminal whose child is the
same forge `podman run`.

## Purpose

Lock in a single, falsifiable runtime contract for Tillandsias' interactive
surface so that:

- New agents are added by editing the forge image, not by adding host-side
  launchers.
- Mount discipline is uniform: only the project workspace and CA cert ever
  leave the host; everything else is `tmpfs` or an ephemeral tempdir.
- The audit story is simple — anything that touches user code lives in one
  image and is reached through one launcher seam.
- Host environments stay clean: no shell PATH pollution, no host-side
  credential exposure, no per-distro install drift between developers.

## Requirements

### Requirement: Forge Image Bakes the Full Agent Set

The forge image (`tillandsias-forge`) MUST contain on `$PATH` after build:

- `claude` (Anthropic Claude Code CLI)
- `codex` (Codex code-analysis CLI)
- `opencode` (OpenCode CLI + `opencode serve` web mode)
- `bash` (maintenance shell)

`command -v claude codex opencode bash` MUST print four valid paths from
inside a freshly built forge container. New interactive agents MUST be added
by extending the forge image, never by installing on the host.

#### Scenario: Fresh forge image contains every agent CLI

- **WHEN** `podman run --rm --entrypoint /bin/sh tillandsias-forge:v<VERSION> -c
  "command -v claude codex opencode bash"` runs (resolved via `forge_image_tag()`,
  never `:latest`)
- **THEN** stdout MUST list four absolute paths
- **AND** the command MUST exit `0`
- **AND** the host MUST NOT need any of these binaries to be present locally

### Requirement: All Podman Run Goes Through the Idiomatic Layer

All `podman run` (and `podman create`/`podman start`) invocations originating
from `crates/tillandsias-headless/` MUST go through
`tillandsias-podman::PodmanClient::run_container` or be assembled with
`ContainerSpec::build_run_args`. There MUST be no `Command::new("podman")` —
or equivalent shell-out — in the tray or headless launch paths, and the
shell scripts that bootstrap the runtime (`build.sh`,
`scripts/build-image.sh`, `scripts/tillandsias-podman`) MUST route through
the same idiomatic boundary.

A documented escape hatch is allowed for genuine bootstrap-time podman calls
that pre-date the orchestrator: such call sites MUST carry an inline
`// allowed-bootstrap` (or `# allowed-bootstrap`) annotation on the same line,
and they remain subject to review.

#### Scenario: A grep over the launch surface finds no raw podman shell-outs

- **WHEN** the litmus test scans `crates/tillandsias-headless/src/`,
  `scripts/tillandsias-podman`, `scripts/build-image.sh`, and `build.sh`
- **THEN** it MUST find zero `Command::new("podman")` occurrences outside of
  `tillandsias-podman` itself
- **AND** it MUST find zero non-annotated shell-outs to bare `podman`
- **AND** any allowed exception MUST be tagged `// allowed-bootstrap` /
  `# allowed-bootstrap` on the same line

### Requirement: No Host-Side Agent Binaries

The tray launch path MUST NOT introduce host-side agent binaries. This means:

- No `Command::new("claude")`, `Command::new("codex")`, or
  `Command::new("opencode")` anywhere in
  `crates/tillandsias-headless/src/` or `crates/tillandsias-podman/src/`.
- No PATH probing for those agents on the host. The host MAY only check
  for podman, the host terminal emulator (`foot`, `gnome-terminal`, etc.),
  and tooling for image builds.
- The tray MUST refuse to launch an agent if the forge image is missing —
  it MUST NOT silently fall back to a host binary.

#### Scenario: A developer without `claude` on $PATH still launches Claude

- **WHEN** the user has no `claude` binary on the host
- **AND** they click "Attach Here" (Claude mode) in the tray
- **THEN** the launcher MUST shell into the forge via `launch_forge_agent`
- **AND** the forge MUST `exec claude` inside the container
- **AND** the host MUST never check `$PATH` for `claude`

### Requirement: Mount Categories Are Exhaustive

Mount sources passed to a forge container MUST belong to exactly one of these
categories:

1. **Canonical project workspace** — the directory the user selected as the
   project root, mounted at `/home/forge/src/<project>`.
2. **CA cert directory** — the ephemeral certs dir produced by
   `ensure_enclave_for_project`, mounted read-only.
3. **`tmpfs`** — declared via `--tmpfs` for ephemeral storage inside the
   container.
4. **`mktemp -d` tempdir** — a fresh, per-launch host tempdir for control
   sockets or short-lived state, cleaned up on container exit.

The user's `$HOME` (or any subdirectory thereof other than the canonical
project workspace and the certs dir) MUST NEVER be bind-mounted into the
forge. Host config (`~/.config`), host caches (`~/.cache`), and host secrets
stores MUST be unreachable from inside the forge.

#### Scenario: Bind-mount audit of a forge launch

- **WHEN** the launcher constructs `ContainerSpec` for any forge mode
- **THEN** every `-v`/`--mount`/`--tmpfs` argument MUST resolve to one of
  the four categories above
- **AND** no path under the user's `$HOME` outside the project workspace
  MUST appear as a bind-mount source
- **AND** host-mounted project launches MUST set
  `TILLANDSIAS_PROJECT_HOST_MOUNT=1`
- **AND** forge entrypoints MUST treat that mount as authoritative project
  state and MUST NOT remove or clone over `/home/forge/src/<project>`
- **AND** the `launch_forge_agent_does_not_mount_user_home` regression test
  MUST hold

### Requirement: Attached forge exit cleans idle stacks

Foreground forge launches SHALL not leave proxy, git, inference, or status
check containers running after the attached forge exits. The cleanup pass MUST
first check whether any `tillandsias-*-forge` container remains active; shared
stack containers are removed only when no active forge containers remain.

#### Scenario: User exits the maintenance shell

- **WHEN** `tillandsias --bash <project> --debug` starts proxy, git,
  inference, and a forge shell
- **AND** the user exits the forge shell
- **THEN** the parent process SHALL remove the project git container
- **AND** it SHALL remove shared proxy and inference containers when no other
  forge container remains active
- **AND** a debug line SHALL state that no active forge containers remain

### Requirement: Delegated agent results come from the current scoped run

A delegated agent run is exactly a nonblank prompt combined with
`TILLANDSIAS_AGENT_RESULT_FORMAT=json`. It MUST also carry a nonempty
`TILLANDSIAS_FORGE_INSTANCE`; otherwise the launcher MUST fail before container
startup because timeout cleanup cannot own the legacy unscoped name safely.
Prompted runs without the JSON request retain their existing human-formatted
path, while JSON without a nonblank prompt MUST NOT fall through to an
interactive session.

Both the raw OpenCode builder and the generic Codex builder MUST propagate only
`TILLANDSIAS_AGENT_RESULT_FORMAT=json` into a delegated container. Host timeout
and result-file paths MUST NOT enter container argv or mounts. The idiomatic
Podman layer MUST capture stdout produced by that invocation and return its real
process exit status while the existing TUI API continues to inherit stdout.

Current-run capture has these conservative rules:

- Codex assistant text comes from
  `item.completed.item{type:"agent_message",text:...}`; `turn.completed` is
  terminal success.
- OpenCode text comes from `part.text`; only `part.reason == "stop"` is
  terminal success. `tool-calls`, missing reasons, and unknown reasons are
  nonterminal. Error detail comes from `error.data.message`.
- Any observed failure is sticky, and a nonzero or signal exit is authoritative
  failure even if earlier JSON looked successful.
- Empty, malformed, truncated, nonterminal, or capture-overflow transcripts
  MUST NOT report success. Stdout MUST be drained with at most 16 MiB retained;
  overflow is surfaced as failure/indeterminate evidence rather than parsed as
  a complete stream.

Delegated runs MUST use a positive timeout. When no override is supplied, the
bounded default is 900 seconds; zero or invalid overrides fail before launch.
At deadline, the launcher MUST keep the captured run future awaitable, issue a
bounded checked `podman rm --force --ignore` against only the exact
instance-scoped container, reap under a bounded deadline, use `kill_on_drop` as
a Podman-CLI backstop, and repeat the exact removal after reap/backstop to close
the create-after-first-removal race. It MUST never list, glob, or remove sibling
worker names.

When `TILLANDSIAS_AGENT_RESULT_FILE` is requested, the host MUST atomically
replace any preexisting content with an empty current-generation file before
spawn and atomically replace it with the fresh captured stdout afterward. The
host MUST never read that path as outcome evidence.

#### Scenario: A failed Codex or OpenCode delegation is not reported done

- **WHEN** a scoped prompt-driven JSON run emits a terminal-looking event and
  then exits nonzero or emits an error
- **THEN** the delegating process MUST surface `[forge-result] ... FAILED`
- **AND** it MUST return failure rather than treating the work as done
- **AND** any caller result file MUST contain only bytes from the current run

#### Scenario: A delegated worker exceeds its deadline

- **WHEN** an instance-scoped delegated worker does not exit before its deadline
- **THEN** cleanup MUST target only its exact digest-scoped container name
- **AND** the original Podman run MUST be reaped or killed under a bounded
  fallback
- **AND** sibling workers MUST remain alive
- **AND** the outcome MUST be `TIMED OUT`, never success

### Requirement: Host Terminal Is the Only Host-Side Process

For interactive launches, the tray MUST spawn exactly one host-side process:
the user's default terminal emulator (`foot`, `gnome-terminal`,
`alacritty`, `kitty`, `xterm`, …). That terminal's sole responsibility is
to provide a TTY window that hosts `podman run -it` against the forge.

The terminal command MUST be assembled by `detect_host_terminal` and the
podman argv MUST be assembled by `build_forge_agent_run_argv`. The tray
MUST NOT spawn any other host-side process (no editor, no language server,
no agent CLI) on the interactive path.

#### Scenario: Inspect the tray's host-side process tree

- **WHEN** the user clicks "Attach Here" (any mode) and the launch completes
- **THEN** the tray MUST have one child process: the host terminal emulator
- **AND** the terminal's child MUST be `podman run -it … tillandsias-forge:…`
- **AND** the agent process MUST appear only inside the forge container

## Anti-Requirements

This spec explicitly forbids:

- **Host-side agent binaries.** `claude`, `codex`, `opencode`, or any
  successor agent MUST NOT be invoked from the host. Their presence on the
  host's `$PATH` is irrelevant to Tillandsias; the host's copy MUST NEVER be
  the one that runs.
- **Raw `podman run` outside the idiomatic layer.** No
  `Command::new("podman")` in headless/tray code, no fresh `podman run`
  invocations in `build.sh` or other launch-path scripts. Bootstrap-time
  exceptions MUST be annotated `// allowed-bootstrap` /
  `# allowed-bootstrap`.
- **Host `$HOME` bind-mounts.** No `-v $HOME:...`, no `-v ~/.config:...`,
  no `-v ~/.cache:...`, no `-v ~/.ssh:...`. The only `$HOME`-adjacent path
  that may cross the boundary is the explicitly selected project workspace.
- **Silent host fallbacks.** If the forge image is missing or stale, the
  launcher MUST surface a build prompt; it MUST NOT degrade to a host
  binary.
- **Additional host-side processes on the interactive path.** The tray
  spawns the terminal emulator and nothing else. No editor, no LSP, no
  pre-launch shell hooks.

## Sources of Truth

- `cheatsheets/runtime/everything-in-forge.md` — agent-facing summary of
  this contract, the four mount categories, and the host-terminal seam.
- `images/default/Containerfile` — the forge image definition; line 29
  (`RUN npm install -g --prefix /usr/local opencode-ai@latest …
  @anthropic-ai/claude-code`) bakes the agent set.
- `crates/tillandsias-headless/src/main.rs` —
  - `launch_forge_agent` (interactive Claude / Codex / OpenCode /
    Maintenance launches)
  - `run_forge_agent_cli_mode` (direct `--codex`, `--claude`, `--bash`)
  - `run_opencode_web_mode` (OpenCode Web launch)
  - `build_forge_agent_run_args`, `build_forge_agent_run_argv`, and
    `detect_host_terminal` (the host terminal seam)
- `crates/tillandsias-podman/src/client.rs` and `container_spec.rs` —
  the idiomatic podman boundary that every launch flows through, including
  bounded current-run stdout capture for delegation.
- `cheatsheets/runtime/podman-control-plane.md` — the broader "one throat
  to choke" framing this spec narrows to interactive agents.

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:

- `litmus:forge-as-only-runtime` — verifies (a) the forge image contains
  `claude`, `codex`, `opencode`, `bash` on `$PATH`, and (b) no raw
  `podman run` shell-outs exist outside the idiomatic layer.
- `litmus:forge-agent-result-format` — verifies JSON propagation, actual
  Codex/OpenCode schemas, fresh capture ownership, real status, bounded
  overflow, and exact-worker timeout cleanup without Podman.

Gating points:

- Forge image bakes all four agent/maintenance CLIs.
- No `Command::new("podman")` in `crates/tillandsias-headless/src/`.
- No raw `podman` shell-outs in `scripts/tillandsias-podman`,
  `scripts/build-image.sh`, or `build.sh` (except entries explicitly
  annotated `// allowed-bootstrap` / `# allowed-bootstrap`).
- No `Command::new("claude" | "codex" | "opencode")` on the host.
- All mount sources resolve to one of the four declared categories.
- The host terminal emulator is the only host-side child of the tray on the
  interactive path.
