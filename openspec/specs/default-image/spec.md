<!-- @trace spec:default-image -->
# default-image Specification

## Status

active

## Purpose
TBD - created by archiving change attach-here-mvp. Update Purpose after archive.
## Requirements
### Requirement: Fedora Minimal base image with dev tools
The default container image SHALL be based on Fedora Minimal and MUST include OpenCode, OpenSpec CLI, Nix, and essential development tools.

#### Scenario: Image contains OpenCode
- **WHEN** the container starts
- **THEN** `opencode` SHALL be available in PATH and executable

#### Scenario: Image contains OpenSpec
- **WHEN** the container starts
- **THEN** `openspec` SHALL be available in PATH (installed or deferred to first run)

#### Scenario: Image contains Nix
- **WHEN** the container starts
- **THEN** `nix` SHALL be available for reproducible builds with flakes enabled

#### Scenario: Image contains git and GitHub CLI
- **WHEN** the container starts
- **THEN** `git` and `gh` SHALL be available in PATH

#### Scenario: Image contains developer quality-of-life tools (bat, delta, git-lfs, httpie, yq)
- **WHEN** the container starts
- **THEN** `bat`, `delta`, `git-lfs`, `httpie`, and `yq` SHALL be available in PATH
- **AND** Git LFS filters SHALL be registered globally

#### Scenario: Image contains additional linters and language servers (pylsp, yamllint, markdownlint, actionlint, vale)
- **WHEN** the container starts
- **THEN** `pylsp`, `yamllint`, `markdownlint`, `actionlint`, and `vale` SHALL be available in PATH and executable

### Requirement: Non-root user with UID 1000
The container SHALL run as user `forge` (UID 1000) to match host user UID via `--userns=keep-id`.

#### Scenario: Volume permissions
- **WHEN** the container mounts a host directory
- **THEN** files created inside the container SHALL be owned by the host user (UID 1000)

### Requirement: Entrypoint launches OpenCode
The container entrypoint SHALL bootstrap the environment and launch OpenCode as the foreground process.

#### Scenario: First run bootstrap
- **WHEN** the container starts for the first time
- **THEN** cache directories SHALL be created, OpenSpec SHALL be installed if deferred, and OpenCode SHALL launch

#### Scenario: Subsequent runs
- **WHEN** the container starts with existing cache
- **THEN** bootstrap MAY be skipped and OpenCode SHALL launch immediately

### Requirement: Declarative image definition via embedded Containerfiles
The default forge image SHALL be built from the embedded Containerfiles and supporting image sources using direct `podman build` calls. Containerfiles are the primary build path.

#### Scenario: Build forge image
- **WHEN** `scripts/build-image.sh forge` is run
- **THEN** the image SHALL be built via direct `podman build` using `images/forge/Containerfile`

#### Scenario: Build web image
- **WHEN** `scripts/build-image.sh web` is run
- **THEN** the image SHALL be built via direct `podman build` using `images/web/Containerfile`

### Requirement: Image identity is content-hash based with human aliases

The default forge image SHALL use a content-hash canonical tag derived from the image source set.

- Canonical tag MUST be `tillandsias-forge:<CONTENT_HASH>`
- `v<Major>.<Minor>.<YYMMDD>.<Build>` and `:latest` MAY be maintained as human-facing aliases

#### Scenario: Build forge image refreshes hash identity
- **WHEN** `scripts/build-image.sh forge` is run
- **THEN** the resulting image SHALL be tagged with the canonical content hash
- **AND** the version and latest aliases SHALL be refreshed to point at the same image

### Requirement: Forge image ships an OpenCode Web entrypoint

The default forge image SHALL include `/usr/local/bin/entrypoint-forge-opencode-web.sh`, installed with executable permissions, alongside the existing OpenCode and Claude entrypoints.

#### Scenario: Script is present and executable
- **WHEN** the built forge image is inspected
- **THEN** the file `/usr/local/bin/entrypoint-forge-opencode-web.sh` SHALL exist and be executable
- **AND** the file SHALL be owned consistently with the other entrypoints

### Requirement: OpenCode Web entrypoint runs opencode serve

The web entrypoint SHALL terminate by `exec`-ing `opencode serve --hostname 0.0.0.0 --port 4096`, binding inside the container only, after the standard setup (CA trust, git clone, OpenSpec init, OpenCode install).

#### Scenario: Final exec targets opencode serve
- **WHEN** a web-mode container starts to steady state
- **THEN** the container's PID 1 SHALL be an `opencode serve` process listening on `0.0.0.0:4096` inside the container's netns
- **AND** no terminal UI MUST be launched

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
users MAY select any enumerated model on demand.

#### Scenario: Ultra-tier host uses the baked T1 model for analysis
- **WHEN** the host has a GPU classified as Ultra (>=12GB VRAM) and the
  tray patches the config overlay
- **THEN** `small_model` SHALL be `ollama/llama3.2:3b` (baked T1), MUST NOT be
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
- **AND** the clamp MUST NOT interfere — the clamp only affects the
  default `small_model`, not explicit `--model` overrides

### Requirement: Cooperative split documented in agent instructions

The bundled instructions surfaced to opencode SHALL include guidance
that ollama models are for analysis subtasks (no tool calling required)
and Zen models are for tool-driven work. Future expansion to give
ollama models tool access MUST update this guidance and the spec
together.

#### Scenario: Agent picks the right model for the work
- **WHEN** the agent has a sub-task that's pure analysis (summarize,
  classify, extract)
- **THEN** the instructions SHALL allow it to delegate to
  `ollama/llama3.2:3b` or another local model
- **WHEN** the agent has a tool-driven task (write file, run command,
  commit)
- **THEN** the instructions SHALL keep the work on the Zen tool-caller

### Requirement: Coding-agent harnesses refresh at launch with persistent fallback

Agent harnesses SHALL be refreshed at container launch into the persistent
project tool cache. OpenCode and Claude Code SHALL use their official curl
installers; Codex and OpenSpec SHALL use their declared npm channels. Installer
scripts SHALL be downloaded to a temporary file and executed separately, never
piped directly from `curl` into a shell. A network failure MAY reuse a
previously validated cached binary, but the first launch SHALL fail loudly when
no usable binary exists.

OpenCode's cache SHALL additionally retain a known-good binary that passed the
OpenCode liveness, flag, `OPENCODE_AUTH_CONTENT` parse, credential-count, and
no-`auth.json` contracts. A freshly installed OpenCode that violates any of
those contracts SHALL be rejected and replaced by that last-good binary.

#### Scenario: Launch refreshes harnesses through declared channels
- **WHEN** a forge container starts with working egress
- **THEN** OpenCode and Claude Code SHALL run their official installers
- **AND** Codex and OpenSpec SHALL check their declared npm channels
- **AND** the selected executables SHALL live in the persistent tool cache.

#### Scenario: OpenCode contract failure rolls back
- **WHEN** a newly refreshed OpenCode starts but does not parse an isolated
  runtime `OPENCODE_AUTH_CONTENT` record without creating `auth.json`
- **THEN** that candidate SHALL fail its contract probe
- **AND** the launcher SHALL restore the last-good OpenCode binary
- **AND** a fixed, credential-free rollback message SHALL be logged.

#### Scenario: Offline launch reuses validated cache
- **WHEN** an installer is unreachable and a validated cached binary exists
- **THEN** the forge SHALL reuse the cached binary
- **WHEN** neither a fresh nor cached binary is usable
- **THEN** the forge SHALL fail loudly before trying to launch the harness.

#### Scenario: No runtime overlay build runs
- **WHEN** the user runs `tillandsias <project>` with a fresh or
  existing forge image
- **THEN** the tray MUST NOT invoke `scripts/build-tools-overlay.sh`
  (the script MUST NOT exist in the repo or the embedded source tree)
- **AND** no temporary forge container MUST spawn to populate
  `/home/forge/.tools`
- **AND** no `[tools-overlay]` log lines SHALL appear at attach time

### Requirement: OpenCode consumes Vault authentication without credential files

When the existing Gemini API-key producer at `secret/gemini/api-key` is
configured, OpenCode and OpenCode Web SHALL derive exactly one
`OPENCODE_AUTH_CONTENT` `google` API record inside the forge. The credential
value SHALL flow from Vault to `jq` on stdin and then exist only in the OpenCode
process environment. It SHALL NOT appear in launcher argv, lifecycle logs,
committed fixtures, or persistent files.

Before every OpenCode launch, the entrypoint SHALL remove any real file or
symlink at `$XDG_DATA_HOME/opencode/auth.json` and fail if it cannot prove the
path absent. It SHALL run the selected installed OpenCode against isolated XDG
state and positively assert that `auth list` reports the injected provider and
credential count while no `auth.json` exists. A parse, count, provider, or
no-file failure SHALL stop the launch loudly. When the Gemini key is absent,
the free Zen/local lane SHALL remain available with no Vault token and no
ambient `OPENCODE_AUTH_CONTENT`.

#### Scenario: Configured OpenCode proves in-memory authentication
- **WHEN** `secret/gemini/api-key` exists and an OpenCode entrypoint starts
- **THEN** the entrypoint SHALL derive `{google:{type:"api",key:<value>}}`
  without placing `<value>` in a process argument
- **AND** the selected OpenCode binary SHALL report provider `google` and the
  expected credential count in an isolated positive assertion
- **AND** `$XDG_DATA_HOME/opencode/auth.json` and the assertion's isolated
  `auth.json` SHALL both remain absent.

#### Scenario: Stale credential file fails closed
- **WHEN** `$XDG_DATA_HOME/opencode/auth.json` exists as a file or symlink
- **THEN** the entrypoint SHALL remove it before deriving auth content
- **AND** SHALL refuse to launch if removal or the absence check fails.

#### Scenario: Unconfigured OpenCode preserves the free lane
- **WHEN** Vault contains no Gemini API key
- **THEN** the OpenCode container SHALL receive no provider Vault token
- **AND** the entrypoint SHALL discard ambient `OPENCODE_AUTH_CONTENT`
- **AND** OpenCode SHALL remain available through configured credential-free
  providers.

### Requirement: Agent instructions document subdomain routing convention

The forge image SHALL ship an opencode instruction file at
`/home/forge/.config-overlay/opencode/instructions/web-services.md`
that tells the agent the canonical URL form for any web server it
spawns inside the forge: `http://<project>.<service>.localhost/`,
port `80` always implicit. The instruction file SHALL also list the
service-port conventions (opencode=4096, flutter=8080, vite=5173,
next=3000, storybook=6006, jupyter=8888, streamlit=8501) and
MUST explicitly forbid:

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
- **AND** the agent MUST NOT print `http://localhost:8080/`

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
- **THEN** the command SHALL print a version string (e.g., `Chromium 134.x`) and exit 0

#### Scenario: firefox headless invokable
- **WHEN** an agent inside the forge runs `firefox --version`
- **THEN** the command SHALL print a version string and exit 0
- **AND** `firefox --headless --screenshot=/tmp/test.png https://example.com` SHALL produce a PNG when run with proxy env vars set (egress goes through the enclave proxy)

#### Scenario: WebDriver bridges available
- **WHEN** an agent inside the forge runs `chromedriver --version` and `geckodriver --version`
- **THEN** both commands SHALL print their respective versions and exit 0

#### Scenario: Image size impact bounded
- **WHEN** the forge image is built with the headless browsers added
- **THEN** the image size MUST grow by no more than 600 MB compared to the previous version (target: ~+400 MB; bound: 600 MB to allow for Fedora package transitive deps)

#### Scenario: Drivers are pinned
- **WHEN** the Containerfile fetches `geckodriver` from upstream
- **THEN** the URL SHALL pin a specific version (e.g., `v0.36.0`)
- **AND** the version SHALL be bumped by deliberate Containerfile edits, NOT by `:latest`-style floating refs

### Requirement: Forge image bakes the cheatsheets directory at /opt/cheatsheets/

The forge image (`images/default/Containerfile`) SHALL `COPY cheatsheets/ /opt/cheatsheets/` near the end of the build (after the `/opt/agents/` layer, before the locale-files COPY) and SHALL set `ENV TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets` so agent runtimes can discover the path without hardcoding it. Ownership SHALL be `root:root` and permissions SHALL be world-readable, so the forge user (UID 1000) MAY read but MUST NOT modify any cheatsheet.

#### Scenario: Image build succeeds with cheatsheets present
- **WHEN** the forge image is built via `scripts/build-image.sh forge`
- **THEN** the resulting image SHALL contain `/opt/cheatsheets/INDEX.md` and the seven category subdirectories
- **AND** `podman run --rm <image> ls /opt/cheatsheets/` SHALL list `INDEX.md` plus `runtime/`, `languages/`, `utils/`, `build/`, `web/`, `test/`, `agents/`

#### Scenario: Environment variable is exported
- **WHEN** an agent inside a running forge container runs `printenv TILLANDSIAS_CHEATSHEETS`
- **THEN** the output SHALL be `/opt/cheatsheets`

#### Scenario: Forge user cannot mutate cheatsheets
- **WHEN** the forge user (UID 1000) runs `touch /opt/cheatsheets/INDEX.md`
- **THEN** the call MUST fail with EACCES — `/opt/cheatsheets/` is image-state, not user-state

### Requirement: Forge entrypoint surfaces TILLANDSIAS_CHEATSHEETS to agents

Every forge entrypoint script (`entrypoint-forge-claude.sh`, `entrypoint-forge-opencode.sh`, `entrypoint-forge-opencode-web.sh`, `entrypoint-terminal.sh`) SHALL ensure `TILLANDSIAS_CHEATSHEETS` is in the agent's environment. The image-level `ENV` already covers this; entrypoints MUST NOT unset or shadow it.

#### Scenario: Variable survives entrypoint
- **WHEN** any forge entrypoint launches its agent
- **THEN** the launched agent's process environment SHALL contain `TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets`

### Requirement: forge-welcome.sh prints the cheatsheet location once per session

`forge-welcome.sh` SHALL print a single line of the form `📚 Cheatsheets: /opt/cheatsheets/INDEX.md (cat or rg this file first)` near the top of its output, so agents and humans alike see the discovery path on first attach.

#### Scenario: Welcome line is present
- **WHEN** `forge-welcome.sh` runs at agent startup
- **THEN** its stdout SHALL contain the single-line cheatsheet hint

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
2. MUST NOT create `/opt/cheatsheets/` at image-build time — that directory is created
   by the tmpfs mount at container start.
3. Export `ENV TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets` unchanged (the runtime
   tmpfs view, not the image-baked canonical).

#### Scenario: /opt/cheatsheets/ is tmpfs-backed at runtime; canonical at /opt/cheatsheets-image/

- **WHEN** a forge container starts
- **THEN** `findmnt /opt/cheatsheets -no FSTYPE` SHALL return `tmpfs`
- **AND** `ls /opt/cheatsheets-image/INDEX.md` SHALL succeed (image-baked canonical)
- **AND** `ls /opt/cheatsheets/INDEX.md` SHALL succeed (runtime tmpfs view, populated
  by `populate_hot_paths()`)

#### Scenario: populate_hot_paths copies image-baked content to tmpfs at entrypoint

- **WHEN** the forge entrypoint runs `populate_hot_paths()`
- **THEN** `/opt/cheatsheets/` SHALL contain the same files as `/opt/cheatsheets-image/`
- **AND** the copy SHALL be a `cp -a` (preserving permissions and timestamps)
- **AND** running `populate_hot_paths()` a second time SHALL be idempotent (safe to call
  from multiple entrypoints via `lib-common.sh`)

### Requirement: OpenCode config includes 4 new instruction files
The `images/default/config-overlay/opencode/config.json` instructions list SHALL expand from 3 to 5 files to include methodology index and 4 action-first sub-files.

#### Scenario: config.json lists all 5 instruction files in order
- **WHEN** the default forge image is built
- **THEN** `config.json` instructions array SHALL include these paths in order:
  - `/home/forge/.config-overlay/opencode/instructions/methodology.md`
  - `/home/forge/.config-overlay/opencode/instructions/forge-discovery.md`
  - `/home/forge/.config-overlay/opencode/instructions/cache-discipline.md`
  - `/home/forge/.config-overlay/opencode/instructions/nix-first.md`
  - `/home/forge/.config-overlay/opencode/instructions/openspec-workflow.md`
  - (plus existing flutter.md, model-routing.md, web-services.md as additional references)

#### Scenario: Agent reads methodology.md first
- **WHEN** OpenCode loads config.json
- **THEN** the first instruction file SHALL be methodology.md
- **THEN** methodology.md SHALL direct the agent to the 4 sub-files for specific workflows

### Requirement: config-overlay installs 4 new instruction files
The `images/default/config-overlay/opencode/instructions/` directory SHALL contain 4 new markdown files, each under 200 lines and action-first in structure.

#### Scenario: forge-discovery.md exists
- **WHEN** the image is built
- **THEN** `/home/forge/.config-overlay/opencode/instructions/forge-discovery.md` SHALL exist and be readable
- **THEN** the file SHALL contain inventory, cheatsheet discovery, and openspec workflow guidance

#### Scenario: cache-discipline.md exists
- **WHEN** the image is built
- **THEN** `/home/forge/.config-overlay/opencode/instructions/cache-discipline.md` SHALL exist and be readable
- **THEN** the file SHALL contain the four-category path model and per-language env vars

#### Scenario: nix-first.md exists
- **WHEN** the image is built
- **THEN** `/home/forge/.config-overlay/opencode/instructions/nix-first.md` SHALL exist and be readable
- **THEN** the file SHALL contain Nix flake guidance for new projects

#### Scenario: openspec-workflow.md exists
- **WHEN** the image is built
- **THEN** `/home/forge/.config-overlay/opencode/instructions/openspec-workflow.md` SHALL exist and be readable
- **THEN** the file SHALL contain step-by-step workflow with proposal, design, specs, tasks, archive

### Requirement: methodology.md becomes an index
The `images/default/config-overlay/opencode/instructions/methodology.md` file SHALL be rewritten as a ~15-line index that points agents to the 4 sub-files, replacing the current 36-line generic principles document.

#### Scenario: methodology.md is concise and actionable
- **WHEN** agent reads methodology.md
- **THEN** the file SHALL be under 20 lines
- **THEN** each line SHALL describe when to read which sub-file

#### Scenario: methodology.md maintains core principles section
- **WHEN** agent needs a reminder of the five core principles (monotonic convergence, CRDT, spec-is-truth, ephemeral-first, privacy-first)
- **THEN** methodology.md SHALL include a short "Core Principles" section linking to the deeper guidance in sub-files

### Requirement: Forge image ships the host-browser MCP stub

The forge image SHALL ship a stdio↔control-socket bridge stub at
`/home/forge/.config-overlay/mcp/host-browser.sh`. The stub SHALL be
invoked by the agent's MCP runtime (OpenCode / Claude Code config) and
SHALL relay JSON-RPC frames between the agent's stdio and the host
control socket bound at `$TILLANDSIAS_CONTROL_SOCKET`
(`/run/host/tillandsias/control.sock`).

The stub MUST:

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
- **THEN** the stub SHALL connect to `$TILLANDSIAS_CONTROL_SOCKET`
- **AND** SHALL complete `Hello`/`HelloAck`
- **AND** an agent-issued `tools/list` SHALL reach the host MCP module and
  the response — listing the eight `browser.*` tools — SHALL reach the
  agent within 500 ms

#### Scenario: Stub fails clearly when env var is missing

- **WHEN** the stub is invoked in a context where
  `TILLANDSIAS_CONTROL_SOCKET` is unset or the socket file does not
  exist
- **THEN** the stub MUST write a one-line error to stderr naming the
  missing variable / unreachable path
- **AND** SHALL exit with a non-zero status
- **AND** MUST write a JSON-RPC error response on stdout for the in-flight
  `initialize` request so the agent's MCP client surfaces a clean
  failure rather than a 60 s timeout

#### Scenario: Stub disconnect on EOF

- **WHEN** the agent closes stdin (terminating the MCP server lifecycle)
- **THEN** the stub SHALL close its socket connection cleanly within 1 s
- **AND** SHALL exit with status 0
- **AND** the host-side `WindowRegistry` SHALL retain any open windows per
  the host-browser-mcp window-survival requirement


### Requirement: Agent permission defaults — pre-grant container-local filesystem; enforce at the boundary

Inside a forge container, agent-level permission prompts for the container's own
filesystem are security theater. The forge is ephemeral, single-project, and
already contained by real boundaries that operate below the agent layer. The
agent's own sandbox adds no meaningful security; it only stalls unattended
/meta-orchestration loops.

Therefore, ALL forge agent configs (OpenCode, Codex, Claude) SHALL pre-grant
read/write access to the container-local filesystem by default, with zero
filesystem permission prompts. The real enforcement lives at the boundary and
SHALL be strengthened there, not in agent-level prompts.

The containment boundaries that make default-grant safe are:

1. **No kernel capabilities** (`--cap-drop=ALL`): the forge process has no
   privileges — cannot load modules, change ownership, or escape the container.
2. **No privilege escalation** (`--security-opt=no-new-privileges`): even if a
   setuid binary existed, the process cannot gain new privileges.
3. **User namespace isolation** (`--userns=keep-id`): the container UID (1000)
   maps to the host UID but cannot interact with host processes or namespaces.
4. **Proxy-mediated egress** (enclave network): all outbound traffic routes
   through the enclave proxy (Squid), which enforces a strict domain allowlist.
   An agent that can write arbitrary files cannot exfiltrate data because no
   unproxied egress path exists.
5. **Credential indirection and scoping**: the forge has no raw GitHub token;
   git operations go through the mirror service. Provider credentials are
   absent unless the owning provider contract explicitly mounts a
   least-privilege Vault token. OpenCode's optional Gemini source is adapted
   only into its process environment, never launcher argv, logs, fixtures, or
   `auth.json`.
6. **Source-mount credential quarantine** (order 170): when the forge source
   mount overlaps the host checkout, host `~/.gitconfig`, `~/.config/gh`, and
   `~/.ssh` are masked with forge-owned empty overlays. Host credentials never
   enter the container.
7. **Encrypted control channel** (order 141): the host↔guest vsock is encrypted
   and version-bound (Noise protocol, ChaCha20-Poly1305). A compromised agent
   cannot inject arbitrary commands into the host or other containers.
8. **SELinux Phase 6 (planned)**: future release will apply SELinux MCS labels
   to the forge domain, adding mandatory access control at the boundary layer.
9. **Ephemeral, single-project container**: each forge is created per project
   attach and destroyed on detach. Cross-project data cannot accumulate.

No agent-level permission prompt protects against a threat that any of these
nine boundaries already contains. Strengthening the boundaries is the correct
long-term approach; default-granting the container-local filesystem eliminates
theater without weakening security.

#### Scenario: Fresh forge session runs with zero filesystem prompts
- **WHEN** a forge container starts and a configured agent (OpenCode, Codex,
  or Claude) is launched
- **THEN** the agent SHALL NOT prompt for filesystem read/write permissions
- **AND** the agent SHALL be able to read `/etc`, `/proc`, `/tmp`, `/usr`,
  `/opt` and write to `/home/forge/**` without user approval
- **AND** no "allow this filesystem path" prompt SHALL appear during
  `/meta-orchestration`, diagnostics, or normal agent operations

#### Scenario: Boundary enforcement is documented, not folkloric
- **WHEN** an operator or auditor asks "why is default-grant safe inside the
  forge?"
- **THEN** the answer SHALL reference the nine containment boundaries listed
  above, not assumptions about agent behavior

### Requirement: Forge validation profile is non-destructive and machine-readable

The repository SHALL provide `scripts/forge-validate.sh` as the maximal safe
validation profile for agents running inside a forge. It SHALL check the push
credential prerequisites, a client-to-origin dry-run push route, the workspace build,
the complete headless forge test target, forge service health, and local-build
e2e eligibility without performing a destructive reset. Each check SHALL emit
exactly one stable `PASS`, `SKIP`, or `FAIL` row, followed by a `SUMMARY` row.
The command SHALL exit non-zero if and only if at least one check fails. Service
health SHALL cover the enclave proxy, Git mirror, inference service, Vault, and
outbound HTTPS when executed in a forge; non-forge hosts SHALL report that check
as an explicit skip.

#### Scenario: Forge without Podman remains a valid validation host

- **WHEN** credential validation and the headless forge test target pass
- **AND** `scripts/e2e-preflight.sh eligibility` emits a valid `skip:<reason>`
- **THEN** the profile SHALL report e2e eligibility as `SKIP`
- **AND** SHALL exit successfully with zero failures in its summary

#### Scenario: Invalid or failed checks fail the profile

- **WHEN** a check exits unsuccessfully or emits a verdict outside its defined
  grammar
- **THEN** the profile SHALL emit a stable `FAIL` row for that check
- **AND** SHALL exit non-zero after emitting its summary

#### Scenario: Credential prerequisites do not substitute for push-route validation

- **WHEN** the credential guard reports an available channel
- **THEN** the profile SHALL also run `git push --dry-run`
  against the current branch
- **AND** SHALL fail if the client cannot negotiate the configured origin route
- **AND** SHALL NOT represent the dry-run as proof that a mirror's upstream
  relay credentials are valid, because dry-run does not invoke pre-receive

## Sources of Truth

- `cheatsheets/runtime/forge-container.md` — Forge Container reference and patterns
- `cheatsheets/build/cargo.md` — Cargo reference and patterns

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`
- `litmus:claude-launch-stability-shape` — Claude TUI runtime and credential-free launch boundary
- `litmus:forge-validation-profile` — non-destructive stable forge validation report
- `litmus:opencode-vault-auth-content` — OpenCode Vault adapter, installed-binary positive assertion, no-file contract, and last-good rollback

Gating points:
- Default forge image is pulled fresh; cached images are cleared on container stop
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:default-image" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
