<!-- @trace spec:default-image -->
# default-image Specification

## Purpose
TBD - created by archiving change attach-here-mvp. Update Purpose after archive.
## Requirements
### Requirement: Fedora Minimal base image with dev tools
The default container image SHALL be based on Fedora Minimal and include OpenCode, OpenSpec CLI, Nix, and essential development tools.

#### Scenario: Image contains OpenCode
- **WHEN** the container starts
- **THEN** `opencode` is available in PATH and executable

#### Scenario: Image contains OpenSpec
- **WHEN** the container starts
- **THEN** `openspec` is available in PATH (installed or deferred to first run)

#### Scenario: Image contains Nix
- **WHEN** the container starts
- **THEN** `nix` is available for reproducible builds with flakes enabled

#### Scenario: Image contains git and GitHub CLI
- **WHEN** the container starts
- **THEN** `git` and `gh` are available in PATH

### Requirement: Non-root user with UID 1000
The container SHALL run as user `forge` (UID 1000) to match host user UID via `--userns=keep-id`.

#### Scenario: Volume permissions
- **WHEN** the container mounts a host directory
- **THEN** files created inside the container are owned by the host user (UID 1000)

### Requirement: Entrypoint launches OpenCode
The container entrypoint SHALL bootstrap the environment and launch OpenCode as the foreground process.

#### Scenario: First run bootstrap
- **WHEN** the container starts for the first time
- **THEN** cache directories are created, OpenSpec is installed if deferred, and OpenCode launches

#### Scenario: Subsequent runs
- **WHEN** the container starts with existing cache
- **THEN** bootstrap is skipped and OpenCode launches immediately

### Requirement: Declarative image definition via flake.nix
The default forge image SHALL be defined declaratively in flake.nix using Nix's dockerTools, replacing the Containerfile as the primary build path.

#### Scenario: Build forge image
- **WHEN** `scripts/build-image.sh forge` is run
- **THEN** the image is built via `nix build .#forge-image` inside the builder toolbox

#### Scenario: Build web image
- **WHEN** `scripts/build-image.sh web` is run
- **THEN** the image is built via `nix build .#web-image` inside the builder toolbox

### Requirement: Forge image ships an OpenCode Web entrypoint

The default forge image SHALL include `/usr/local/bin/entrypoint-forge-opencode-web.sh`, installed with executable permissions, alongside the existing OpenCode and Claude entrypoints.

#### Scenario: Script is present and executable
- **WHEN** the built forge image is inspected
- **THEN** the file `/usr/local/bin/entrypoint-forge-opencode-web.sh` exists and is executable
- **AND** the file is owned consistently with the other entrypoints

### Requirement: OpenCode Web entrypoint runs opencode serve

The web entrypoint SHALL terminate by `exec`-ing `opencode serve --hostname 0.0.0.0 --port 4096`, binding inside the container only, after the standard setup (CA trust, git clone, OpenSpec init, OpenCode install).

#### Scenario: Final exec targets opencode serve
- **WHEN** a web-mode container starts to steady state
- **THEN** the container's PID 1 is an `opencode serve` process listening on `0.0.0.0:4096` inside the container's netns
- **AND** no terminal UI is launched

### Requirement: Default opencode model is a tool-capable Zen provider

The bundled `images/default/config-overlay/opencode/config.json` SHALL
set `model` to a tool-capable Zen model (default:
`opencode/big-pickle`). `small_model` SHALL be clamped at runtime to a
model that is **image-baked** in the inference container — either
`ollama/qwen2.5:0.5b` (T0, always baked) or `ollama/llama3.2:3b` (T1,
always baked) — regardless of detected GPU tier.

Claiming a larger tier-tagged model in `small_model` when that model
isn't in the inference cache leaves opencode's sub-tasks pointing at a
model that doesn't exist. Squid's SSL-bump can't reliably pull the big
ollama manifests at runtime (see project memory `project_squid_ollama_eof`),
so tier-upgrades past T1 are a user-driven opt-in via
`--model ollama/<name>` after they've manually pulled what they want.

The `ollama` provider SHALL remain fully enumerated in the config so
users can select any enumerated model on demand.

#### Scenario: Ultra-tier host uses the baked T1 model for analysis
- **WHEN** the host has a GPU classified as Ultra (>=12GB VRAM) and the
  tray patches the config overlay
- **THEN** `small_model` SHALL be `ollama/llama3.2:3b` (baked T1), NOT
  `ollama/qwen2.5:14b` or any other non-baked model
- **AND** opencode sub-tasks SHALL succeed on a freshly-attached project
  with no manual model pulls

#### Scenario: First `opencode run` from a fresh attach uses a Zen model
- **WHEN** a forge container is freshly attached to a project
- **AND** the user runs `opencode run "<prompt>"` with no `--model`
- **THEN** the request SHALL go to `opencode/big-pickle` (or the
  configured Zen default)
- **AND** the run SHALL be capable of tool calling (write_file,
  bash_exec, etc.)

#### Scenario: User opts into a larger model
- **WHEN** the user manually runs `ollama pull qwen2.5:14b` inside the
  inference container
- **AND** later runs `opencode run --model ollama/qwen2.5:14b
  "<prompt>"`
- **THEN** the request SHALL route to that model
- **AND** the clamp SHALL NOT interfere — the clamp only affects the
  default `small_model`, not explicit `--model` overrides

### Requirement: Cooperative split documented in agent instructions

The bundled instructions surfaced to opencode SHALL include guidance
that ollama models are for analysis subtasks (no tool calling required)
and Zen models are for tool-driven work. Future expansion to give
ollama models tool access SHALL update this guidance and the spec
together.

#### Scenario: Agent picks the right model for the work
- **WHEN** the agent has a sub-task that's pure analysis (summarize,
  classify, extract)
- **THEN** the instructions SHALL allow it to delegate to
  `ollama/llama3.2:3b` or another local model
- **WHEN** the agent has a tool-driven task (write file, run command,
  commit)
- **THEN** the instructions SHALL keep the work on the Zen tool-caller

### Requirement: Coding agents are image-baked, not runtime-installed

Claude Code, OpenCode, and OpenSpec SHALL be installed into the forge
image at `podman build` time. The binaries SHALL live under
`/opt/agents/{claude,opencode,openspec}/` with symlinks at
`/usr/local/bin/{claude,opencode,openspec}`. No runtime installer
(npm, curl | bash) SHALL run on each attach.

Rationale: the prior runtime tools overlay re-installed these agents on
every launch into a bind-mounted `/home/forge/.tools` directory. It
added ~7s to every attach, routinely failed the OpenCode install
(dropping the binary outside the overlay target path), and duplicated
work whose output was already in the image. Hard-install gives
deterministic agent versions per forge image tag, zero runtime
network for agents, and one fewer failure surface.

#### Scenario: Agents resolve from image at attach time
- **WHEN** a forge container is freshly spawned
- **THEN** `which claude opencode openspec` inside the container SHALL
  return `/usr/local/bin/{claude,opencode,openspec}` respectively
- **AND** the binaries SHALL be present without any runtime install
  step running on the host

#### Scenario: No runtime overlay build runs
- **WHEN** the user runs `tillandsias <project>` with a fresh or
  existing forge image
- **THEN** the tray SHALL NOT invoke `scripts/build-tools-overlay.sh`
  (the script SHALL NOT exist in the repo or the embedded source tree)
- **AND** no temporary forge container SHALL spawn to populate
  `/home/forge/.tools`
- **AND** no `[tools-overlay]` log lines SHALL appear at attach time

### Requirement: Agent instructions document subdomain routing convention

The forge image SHALL ship an opencode instruction file at
`/home/forge/.config-overlay/opencode/instructions/web-services.md`
that tells the agent the canonical URL form for any web server it
spawns inside the forge: `http://<project>.<service>.localhost/`,
port `80` always implicit. The instruction file SHALL also list the
service-port conventions (opencode=4096, flutter=8080, vite=5173,
next=3000, storybook=6006, jupyter=8888, streamlit=8501) and
explicitly forbid:

- Binding servers to `localhost` / `127.0.0.1` inside the container.
- Including a port number in the URL given to the human.
- Publishing container ports to the host (`-p`/`--publish`).

The agent SHALL be told to bind `0.0.0.0` on the conventional port
for each service.

#### Scenario: Agent prints a Tillandsias-shaped URL
- **WHEN** the user asks the agent to run a Flutter web app and the
  agent has the `web-services.md` instruction loaded
- **THEN** the agent SHALL launch with
  `flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8080`
- **AND** the agent SHALL tell the user to open
  `http://<project>.flutter.localhost/`
- **AND** the agent SHALL NOT print `http://localhost:8080/`

#### Scenario: Agent self-tests through the proxy
- **WHEN** the agent wants to verify its server is up before reporting
  to the user
- **THEN** it SHALL `curl http://<project>.<service>.localhost/`
- **AND** the request SHALL succeed via the existing
  `HTTP_PROXY=http://proxy:3128` env var (no extra setup required by
  the agent)

### Requirement: Forge ships headless Chromium and headless Firefox with WebDriver bridges

The forge image SHALL install `chromium-headless` (Fedora's headless-only Chromium build), `firefox` (used in `--headless` mode), `chromedriver` (the W3C WebDriver server for Chromium), and `geckodriver` (the Mozilla WebDriver server for Firefox; pinned upstream binary because Fedora doesn't package it). All four binaries SHALL be on the default `$PATH` for the forge user (UID 1000).

The full-Chrome / full-Firefox GUI variants are intentionally NOT installed — interactive browser windows belong to the host (per the `host-chromium-on-demand` capability), not to the forge. The forge needs only the headless variants for agent-driven testing (Selenium, Playwright, raw WebDriver).

#### Scenario: chromium-headless invokable
- **WHEN** an agent inside the forge runs `chromium-headless --version`
- **THEN** the command prints a version string (e.g., `Chromium 134.x`) and exits 0

#### Scenario: firefox headless invokable
- **WHEN** an agent inside the forge runs `firefox --version`
- **THEN** the command prints a version string and exits 0
- **AND** `firefox --headless --screenshot=/tmp/test.png https://example.com` produces a PNG when run with proxy env vars set (egress goes through the enclave proxy)

#### Scenario: WebDriver bridges available
- **WHEN** an agent inside the forge runs `chromedriver --version` and `geckodriver --version`
- **THEN** both commands print their respective versions and exit 0

#### Scenario: Image size impact bounded
- **WHEN** the forge image is built with the headless browsers added
- **THEN** the image size SHALL grow by no more than 600 MB compared to the previous version (target: ~+400 MB; bound: 600 MB to allow for Fedora package transitive deps)

#### Scenario: Drivers are pinned
- **WHEN** the Containerfile fetches `geckodriver` from upstream
- **THEN** the URL SHALL pin a specific version (e.g., `v0.36.0`)
- **AND** the version SHALL be bumped by deliberate Containerfile edits, not by `:latest`-style floating refs

### Requirement: Forge image bakes the cheatsheets directory at /opt/cheatsheets/

The forge image (`images/default/Containerfile`) SHALL `COPY cheatsheets/ /opt/cheatsheets/` near the end of the build (after the `/opt/agents/` layer, before the locale-files COPY) and SHALL set `ENV TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets` so agent runtimes can discover the path without hardcoding it. Ownership SHALL be `root:root` and permissions SHALL be world-readable, so the forge user (UID 1000) can read but not modify any cheatsheet.

#### Scenario: Image build succeeds with cheatsheets present
- **WHEN** the forge image is built via `scripts/build-image.sh forge`
- **THEN** the resulting image contains `/opt/cheatsheets/INDEX.md` and the seven category subdirectories
- **AND** `podman run --rm <image> ls /opt/cheatsheets/` lists `INDEX.md` plus `runtime/`, `languages/`, `utils/`, `build/`, `web/`, `test/`, `agents/`

#### Scenario: Environment variable is exported
- **WHEN** an agent inside a running forge container runs `printenv TILLANDSIAS_CHEATSHEETS`
- **THEN** the output is `/opt/cheatsheets`

#### Scenario: Forge user cannot mutate cheatsheets
- **WHEN** the forge user (UID 1000) runs `touch /opt/cheatsheets/INDEX.md`
- **THEN** the call fails with EACCES — `/opt/cheatsheets/` is image-state, not user-state

### Requirement: Forge entrypoint surfaces TILLANDSIAS_CHEATSHEETS to agents

Every forge entrypoint script (`entrypoint-forge-claude.sh`, `entrypoint-forge-opencode.sh`, `entrypoint-forge-opencode-web.sh`, `entrypoint-terminal.sh`) SHALL ensure `TILLANDSIAS_CHEATSHEETS` is in the agent's environment. The image-level `ENV` already covers this; entrypoints SHALL NOT unset or shadow it.

#### Scenario: Variable survives entrypoint
- **WHEN** any forge entrypoint launches its agent
- **THEN** the launched agent's process environment contains `TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets`

### Requirement: forge-welcome.sh prints the cheatsheet location once per session

`forge-welcome.sh` SHALL print a single line of the form `📚 Cheatsheets: /opt/cheatsheets/INDEX.md (cat or rg this file first)` near the top of its output, so agents and humans alike see the discovery path on first attach.

#### Scenario: Welcome line is present
- **WHEN** `forge-welcome.sh` runs at agent startup
- **THEN** its stdout contains the single-line cheatsheet hint

### Requirement: Forge image ships cheatsheets at /opt/cheatsheets-image (image-baked canonical)

The forge image (`images/default/Containerfile`) SHALL bake cheatsheets at
`/opt/cheatsheets-image/` (the immutable lower-layer copy) rather than at
`/opt/cheatsheets/` (which is now a runtime tmpfs mount populated by
`populate_hot_paths()` in every forge entrypoint).

> Delta: the COPY target in the Containerfile moves from `/opt/cheatsheets` to
> `/opt/cheatsheets-image`. The path `/opt/cheatsheets` is now a runtime tmpfs
> mount populated by `populate_hot_paths()` in every forge entrypoint.
> `/opt/cheatsheets-image` is the immutable, image-baked lower-layer copy.

1. `COPY cheatsheets/ /opt/cheatsheets-image/` at image-build time (lower-layer bake).
2. NOT create `/opt/cheatsheets/` at image-build time — that directory is created
   by the tmpfs mount at container start.
3. Export `ENV TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets` unchanged (the runtime
   tmpfs view, not the image-baked canonical).

#### Scenario: /opt/cheatsheets/ is tmpfs-backed at runtime; canonical at /opt/cheatsheets-image/

- **WHEN** a forge container starts
- **THEN** `findmnt /opt/cheatsheets -no FSTYPE` returns `tmpfs`
- **AND** `ls /opt/cheatsheets-image/INDEX.md` succeeds (image-baked canonical)
- **AND** `ls /opt/cheatsheets/INDEX.md` succeeds (runtime tmpfs view, populated
  by `populate_hot_paths()`)

#### Scenario: populate_hot_paths copies image-baked content to tmpfs at entrypoint

- **WHEN** the forge entrypoint runs `populate_hot_paths()`
- **THEN** `/opt/cheatsheets/` contains the same files as `/opt/cheatsheets-image/`
- **AND** the copy is a `cp -a` (preserving permissions and timestamps)
- **AND** running `populate_hot_paths()` a second time is idempotent (safe to call
  from multiple entrypoints via `lib-common.sh`)

### Requirement: OpenCode config includes 4 new instruction files
The `images/default/config-overlay/opencode/config.json` instructions list SHALL expand from 3 to 5 files to include methodology index and 4 action-first sub-files.

#### Scenario: config.json lists all 5 instruction files in order
- **WHEN** the default forge image is built
- **THEN** `config.json` instructions array includes these paths in order:
  - `/home/forge/.config-overlay/opencode/instructions/methodology.md`
  - `/home/forge/.config-overlay/opencode/instructions/forge-discovery.md`
  - `/home/forge/.config-overlay/opencode/instructions/cache-discipline.md`
  - `/home/forge/.config-overlay/opencode/instructions/nix-first.md`
  - `/home/forge/.config-overlay/opencode/instructions/openspec-workflow.md`
  - (plus existing flutter.md, model-routing.md, web-services.md as additional references)

#### Scenario: Agent reads methodology.md first
- **WHEN** OpenCode loads config.json
- **THEN** the first instruction file is methodology.md
- **THEN** methodology.md directs the agent to the 4 sub-files for specific workflows

### Requirement: config-overlay installs 4 new instruction files
The `images/default/config-overlay/opencode/instructions/` directory SHALL contain 4 new markdown files, each under 200 lines and action-first in structure.

#### Scenario: forge-discovery.md exists
- **WHEN** the image is built
- **THEN** `/home/forge/.config-overlay/opencode/instructions/forge-discovery.md` exists and is readable
- **THEN** the file contains inventory, cheatsheet discovery, and openspec workflow guidance

#### Scenario: cache-discipline.md exists
- **WHEN** the image is built
- **THEN** `/home/forge/.config-overlay/opencode/instructions/cache-discipline.md` exists and is readable
- **THEN** the file contains the four-category path model and per-language env vars

#### Scenario: nix-first.md exists
- **WHEN** the image is built
- **THEN** `/home/forge/.config-overlay/opencode/instructions/nix-first.md` exists and is readable
- **THEN** the file contains Nix flake guidance for new projects

#### Scenario: openspec-workflow.md exists
- **WHEN** the image is built
- **THEN** `/home/forge/.config-overlay/opencode/instructions/openspec-workflow.md` exists and is readable
- **THEN** the file contains step-by-step workflow with proposal, design, specs, tasks, archive

### Requirement: methodology.md becomes an index
The `images/default/config-overlay/opencode/instructions/methodology.md` file SHALL be rewritten as a ~15-line index that points agents to the 4 sub-files, replacing the current 36-line generic principles document.

#### Scenario: methodology.md is concise and actionable
- **WHEN** agent reads methodology.md
- **THEN** the file is under 20 lines
- **THEN** each line describes when to read which sub-file

#### Scenario: methodology.md maintains core principles section
- **WHEN** agent needs a reminder of the five core principles (monotonic convergence, CRDT, spec-is-truth, ephemeral-first, privacy-first)
- **THEN** methodology.md includes a short "Core Principles" section linking to the deeper guidance in sub-files

### Requirement: Forge image ships the host-browser MCP stub

The forge image SHALL ship a stdio↔control-socket bridge stub at
`/home/forge/.config-overlay/mcp/host-browser.sh`. The stub SHALL be
invoked by the agent's MCP runtime (OpenCode / Claude Code config) and
SHALL relay JSON-RPC frames between the agent's stdio and the host
control socket bound at `$TILLANDSIAS_CONTROL_SOCKET`
(`/run/host/tillandsias/control.sock`).

The stub SHALL:

1. Connect to `$TILLANDSIAS_CONTROL_SOCKET` (failing with a clear
   error message on stderr if the env var is unset or the socket is
   unreachable, so the agent reports the failure to the user).
2. Perform the `Hello`/`HelloAck` exchange per the
   `tray-host-control-socket` wire format, declaring capability
   `"BrowserMcp"`.
3. Read JSON-RPC frames from stdin (newline-delimited per the existing
   forge MCP convention used by `git-tools.sh`), wrap each as a
   `ControlMessage::McpFrame` postcard envelope length-prefixed with a
   4-byte big-endian length, and write to the socket.
4. Read response envelopes from the socket, unwrap the JSON-RPC payload,
   and write to stdout.
5. Exit cleanly when stdin EOFs OR the socket disconnects.

The stub MAY be implemented as a shell script using `socat` and
`printf`-based length prefixing if `socat` is reliably present in the
forge image; otherwise a tiny Rust binary (≤ 200 KB) baked into the
image SHALL be used. The choice is locked in tasks.md per design.md
Decision 9.

The OpenCode MCP config (`~/.config-overlay/opencode/config.json`)
SHALL register the stub as a `local` MCP server named `host-browser`
under `mcp`:

```json
"host-browser": {
    "type": "local",
    "command": ["/home/forge/.config-overlay/mcp/host-browser.sh"],
    "enabled": true
}
```

The Claude Code MCP config SHALL register the same stub under its
equivalent key, so both agent runtimes see the eight `browser.*` tools.

@trace spec:default-image, spec:host-browser-mcp, spec:tray-host-control-socket

#### Scenario: Stub launches and bridges a tools/list round trip

- **WHEN** an agent inside the forge invokes the configured `host-browser`
  MCP server
- **THEN** the stub connects to `$TILLANDSIAS_CONTROL_SOCKET`
- **AND** completes `Hello`/`HelloAck`
- **AND** an agent-issued `tools/list` reaches the host MCP module and
  the response — listing the eight `browser.*` tools — reaches the
  agent within 500 ms

#### Scenario: Stub fails clearly when env var is missing

- **WHEN** the stub is invoked in a context where
  `TILLANDSIAS_CONTROL_SOCKET` is unset or the socket file does not
  exist
- **THEN** the stub writes a one-line error to stderr naming the
  missing variable / unreachable path
- **AND** exits with a non-zero status
- **AND** writes a JSON-RPC error response on stdout for the in-flight
  `initialize` request so the agent's MCP client surfaces a clean
  failure rather than a 60 s timeout

#### Scenario: Stub disconnect on EOF

- **WHEN** the agent closes stdin (terminating the MCP server lifecycle)
- **THEN** the stub closes its socket connection cleanly within 1 s
- **AND** exits with status 0
- **AND** the host-side `WindowRegistry` retains any open windows per
  the host-browser-mcp window-survival requirement

