## ADDED Requirements

### Requirement: host tools are named by what they do

The host-services MCP surface SHALL advertise every tool under a namespaced canonical name whose prefix is its group: `preview.*` (the local WEB preview lifecycle), `toolchain.*` (shared toolchain images), `image.*` (local image generation), `studio.*` (the headless ComfyUI pipeline), `browser.*` (host browser windows), `cloudflare.*` (read-only account views) and `webstudio.*` (visual co-edit studios). A tool whose flat name was advertised before this change SHALL remain callable under that name as a deprecated alias for one release, SHALL be listed after every canonical tool, and its description SHALL begin `Deprecated alias of <canonical>`.

#### Scenario: a deprecated alias behaves as its canonical name

- **WHEN** `tools/call` names `service_stop` with the same arguments as a call naming `preview.stop`
- **THEN** both replies are identical apart from nothing (same result or the same refusal), and the refusal text names `preview.stop`

#### Scenario: both names share one schema

- **WHEN** `tools/list` is read
- **THEN** every renamed tool appears exactly once under its canonical name and once under its alias, the two `inputSchema` values are equal, and every alias is positioned after every canonical tool

### Requirement: every description says what the tool starts

Each tool description SHALL say what the call starts on the host (a sibling web container, a toolchain image build, the image engine, GPU work in the studio container, a host browser window) or say that it starts nothing.

#### Scenario: the starters are named

- **WHEN** `tools/list` is read
- **THEN** `preview.publish` says it starts a sibling web container, `toolchain.prepare` says it starts a one-time image build, `studio.run_workflow` names the studio container it needs, `webstudio.open` says it starts the studio through the tray (order 2025-e6mi), and `preview.status`, `preview.stop`, `preview.logs`, `webstudio.changes`, `webstudio.publish_request` and `tillandsias.index` say they start nothing

### Requirement: the agent sees a grouped index first

The `initialize` reply SHALL carry `instructions`: one text listing every group with what it does, what it starts and when to use it, the registration name the forge knows the socket by, and the alias table. The tool `tillandsias.index {}` SHALL return the same index as a tool result. Both SHALL be rendered from one table in the tray binary.

#### Scenario: initialize carries the index

- **WHEN** a client sends `initialize`
- **THEN** `result.instructions` names every group prefix and the text equals what `tillandsias.index` returns in its `instructions` field

### Requirement: a studio refusal names the real configuration file

A `studio_unavailable` refusal for a studio container that is not running SHALL name `.tillandsias/config.toml` as the file that opts the project in.

#### Scenario: the remedy is actionable

- **WHEN** `studio.run_workflow` is called for a project whose studio container is not running
- **THEN** the refusal reads `studio_unavailable: <container> is not running; set `[imagegen] studio = true` in the project's .tillandsias/config.toml and relaunch the forge (...)`
