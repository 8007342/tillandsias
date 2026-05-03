# host-browser-mcp Specification

## Status

status: active

## Purpose
TBD - created by archiving change host-browser-mcp. Update Purpose after archive.
## Requirements
### Requirement: Host MCP server exposes browser-control tools to forge agents

The tray application SHALL embed a host-resident MCP server
(`tillandsias-browser-mcp`) implemented as a Rust module that runs in the
tray process. The server SHALL speak MCP JSON-RPC 2.0 per the
`2025-06-18` protocol revision and SHALL respond to `initialize`,
`tools/list`, `tools/call`, `prompts/list`, `resources/list`,
`resources/templates/list`, and `notifications/initialized` methods.

The server SHALL declare a single MCP capability — `tools` — and SHALL
return exactly the eight v1 tools listed below from `tools/list`. Any
other MCP method SHALL be answered with JSON-RPC error
`-32601 Method not found` so the connecting agent does not stall waiting
for a reply.

The eight v1 tools are:

| Tool name | Inputs (JSON Schema sketch) | Output |
|---|---|---|
| `browser.open` | `{ url: string }` | `{ window_id: string }` |
| `browser.list_windows` | `{}` | `{ windows: [{ window_id, url, title }] }` |
| `browser.read_url` | `{ window_id: string }` | `{ url: string, title: string }` |
| `browser.screenshot` | `{ window_id: string, full_page?: boolean }` | `{ png_base64: string, width: u32, height: u32 }` |
| `browser.click` | `{ window_id: string, selector: string }` | `{ ok: boolean }` |
| `browser.type` | `{ window_id: string, selector: string, text: string }` | `{ ok: boolean }` |
| `browser.eval` | `{ window_id: string, expression: string }` | `{ result: any }` |
| `browser.close` | `{ window_id: string }` | `{ ok: boolean }` |

@trace spec:host-browser-mcp, spec:opencode-web-session

#### Scenario: tools/list returns exactly the v1 surface

- **WHEN** an agent in a forge container sends `tools/list` to the MCP server
- **THEN** the response `result.tools` array contains exactly eight entries
- **AND** each entry's `name` field matches one of the eight v1 tool names
- **AND** each entry includes a non-empty `description` and a JSON-Schema
  `inputSchema`
- **AND** no other tools are advertised

#### Scenario: prompts/list and resources/list return empty arrays

- **WHEN** an agent sends `prompts/list` or `resources/list`
- **THEN** the server responds with `{ result: { prompts: [] } }` or
  `{ result: { resources: [] } }` respectively
- **AND** the response is delivered within 100 ms so the agent's UI does
  not stall (matches the existing `git-tools.sh` workaround)

#### Scenario: Unknown method returns -32601

- **WHEN** an agent sends an MCP method this server does not implement
- **THEN** the server replies with JSON-RPC error code `-32601`
- **AND** the error `message` field begins with `Method not found:`
- **AND** the connection remains open for further requests

### Requirement: MCP transport rides the existing host control socket

The MCP server SHALL NOT bind a new socket. Instead, the JSON-RPC byte
stream from each forge container SHALL be carried inside a new
`ControlMessage::McpFrame { session_id: u64, payload: Vec<u8> }` variant
on the `tray-host-control-socket` postcard envelope. The forge-side
client (a stdio shim invoked by the agent's MCP runtime) SHALL connect
to `$TILLANDSIAS_CONTROL_SOCKET`
(`/run/host/tillandsias/control.sock` inside the container per
`tray-host-control-socket`), perform the standard `Hello`/`HelloAck`
exchange, and then bidirectionally relay length-prefixed JSON-RPC frames
wrapped in `McpFrame` envelopes.

`session_id` SHALL be issued by the tray on the first `McpFrame`
received over a given control-socket connection and SHALL persist for
the lifetime of that connection. When the connection drops, the tray
SHALL discard any per-session in-memory state (the `WindowRegistry`
holds windows beyond connection lifetime — see the window-survival
requirement below).

@trace spec:host-browser-mcp, spec:tray-host-control-socket

#### Scenario: Forge stub frames JSON-RPC inside McpFrame

- **WHEN** the forge-side stub reads a JSON-RPC line from the agent's
  stdout
- **THEN** the stub wraps the line as a `ControlMessage::McpFrame {
  session_id, payload }` postcard envelope with the existing 4-byte
  big-endian length prefix
- **AND** writes the framed envelope to
  `/run/host/tillandsias/control.sock`
- **AND** the tray-side reader deserialises the envelope, dispatches the
  `payload` to the MCP server module, and writes the response back as
  another `McpFrame` envelope on the same connection

#### Scenario: No new socket node is created on disk

- **WHEN** the tray starts with `host-browser-mcp` enabled
- **THEN** no additional Unix-domain socket nodes are created beyond
  `$XDG_RUNTIME_DIR/tillandsias/control.sock`
- **AND** an audit of `lsof -U` for the tray PID lists exactly the
  control socket plus any consumer-accepted streams

### Requirement: Browser provider is bundled Chromium only

`browser.open` SHALL launch ONLY the bundled Chromium binary provisioned
by `host-chromium-on-demand` at
`~/.cache/tillandsias/chromium/<version>/chrome` (or the macOS / Windows
equivalent path that capability defines). System Chrome, Safari,
Firefox, Edge, or any other host-installed browser SHALL NOT be used.

If the bundled-Chromium binary is missing or has not finished
downloading, `browser.open` SHALL return MCP tool error
`{ isError: true, content: [{ type: "text", text: "BROWSER_UNAVAILABLE: bundled chromium not yet downloaded" }] }`
without launching anything.

@trace spec:host-browser-mcp, spec:opencode-web-session

#### Scenario: System Chrome is never invoked

- **WHEN** the user has Google Chrome installed at a system path AND
  `browser.open` is called
- **THEN** the `execve(2)` invoked by the tray spawns the binary at
  `~/.cache/tillandsias/chromium/<version>/chrome` (or platform
  equivalent), NOT the system Chrome
- **AND** the spawned process inherits a fresh ephemeral
  `--user-data-dir` so cookies / localStorage from the user's daily
  browser cannot leak into the launched window

#### Scenario: Bundled Chromium not yet downloaded returns BROWSER_UNAVAILABLE

- **WHEN** the bundled-Chromium binary path does not exist on disk
- **AND** an agent calls `browser.open`
- **THEN** the tool result has `isError: true` and contains the literal
  string `BROWSER_UNAVAILABLE`
- **AND** an accountability log entry records the failed launch with
  `category = "browser"`, `spec = "host-browser-mcp"`,
  `outcome = "browser-unavailable"`

### Requirement: Process-per-window with ephemeral profile

Each successful `browser.open(url)` call SHALL spawn a fresh Chromium
process with the following non-negotiable flags:

- `--app=<url>` — single-window app mode
- `--user-data-dir=<path under $XDG_RUNTIME_DIR/tillandsias/mcp/>` —
  ephemeral; deleted when the window closes
- `--incognito` — no persistent state
- `--no-first-run`
- `--no-default-browser-check`
- `--remote-debugging-port=<random ephemeral high port>` — bound to
  `127.0.0.1` only

The tray SHALL attach a CDP client over `ws://127.0.0.1:<port>/devtools/browser`
within 2 s of process spawn, capture the first target id, and register
the tuple `(window_id, pid, cdp_port, target_id)` in an in-process
`WindowRegistry`. The `window_id` SHALL be a fresh UUID v4 with the
prefix `win-`.

A single Chromium process SHALL host exactly one CDP target. The MCP
server SHALL NOT use `Target.createTarget` to multiplex multiple
windows into a single process.

@trace spec:host-browser-mcp, spec:host-chromium-on-demand

#### Scenario: Each open call spawns its own chromium process

- **WHEN** an agent calls `browser.open` twice for two different
  allowlisted URLs in the same project
- **THEN** the host has two distinct chromium PIDs running
- **AND** each PID has its own `--user-data-dir` under
  `$XDG_RUNTIME_DIR/tillandsias/mcp/`
- **AND** the two `--user-data-dir` paths have no shared files

#### Scenario: Ephemeral profile is deleted on window close

- **WHEN** an agent calls `browser.close(window_id)` OR the user closes
  the window manually OR the chromium process exits for any reason
- **THEN** the corresponding `--user-data-dir` directory is removed
  recursively within 5 s
- **AND** the entry is removed from the `WindowRegistry`
- **AND** an accountability log entry records the cleanup

### Requirement: Window survives MCP connection drop

A window opened by `browser.open` SHALL remain open and usable by the
user until any of (a) `browser.close(window_id)` is called, (b) the
user closes the window manually, (c) the tray process quits. A drop of
the originating MCP connection (forge container exit, control-socket
disconnect, agent crash) SHALL NOT terminate the window.

When the originating MCP session ends without an explicit close, the
`WindowRegistry` SHALL retain the entry so a later `browser.list_windows`
from the same project (rebound after reconnect) returns the window.

@trace spec:host-browser-mcp

#### Scenario: Agent disconnect leaves window open

- **WHEN** an agent calls `browser.open` for an allowed URL
- **AND** the forge container exits before calling `browser.close`
- **THEN** the chromium process is still running 30 s later
- **AND** the user can still interact with the window
- **AND** the `WindowRegistry` still contains the entry

#### Scenario: Tray Quit terminates all windows

- **WHEN** the user invokes the tray's Quit menu item
- **THEN** every chromium process spawned by the MCP is terminated
  before tray exit
- **AND** every ephemeral `--user-data-dir` is removed
- **AND** an accountability log entry records each window teardown

### Requirement: URL allowlist denies opencode-self and non-project hosts

`browser.open(url)` SHALL parse `url` using `url::Url` and SHALL accept
the request iff ALL of the following are true:

1. Scheme is exactly `http` or `https`.
2. Host is a domain name (not an IPv4 / IPv6 literal, not bare
   `localhost`).
3. Host ends in `.<project>.localhost` where `<project>` matches the
   forge container's project label exactly (the label is bound to the
   MCP session per the peer-credential authorisation requirement
   below — the agent does NOT supply it).
4. The host's left-most label is NOT `opencode` (the agent's own UI
   per the proposal's critical rule).
5. Port is exactly `8080` (the host-side router publish port per
   `opencode-web-session`).
6. The URL contains no userinfo segment (`user:pass@` form).

Any URL failing any rule SHALL be rejected with a tool result of
`{ isError: true, content: [{ type: "text", text: "URL_NOT_ALLOWED: <reason>" }] }`
where `<reason>` names which rule failed. The chromium process SHALL
NOT be spawned. An accountability log entry SHALL record the rejection
with the failing rule and the project label.

@trace spec:host-browser-mcp, spec:opencode-web-session

#### Scenario: opencode.<project>.localhost is rejected

- **WHEN** an agent in project `acme` calls
  `browser.open({ url: "http://opencode.acme.localhost:8080/" })`
- **THEN** the tool result is `isError: true` containing
  `URL_NOT_ALLOWED`
- **AND** the rejection reason names the `opencode-self` rule
- **AND** no chromium process is spawned

#### Scenario: Cross-project host is rejected

- **WHEN** an agent bound to project `acme` calls
  `browser.open({ url: "http://web.beta.localhost:8080/" })`
- **THEN** the tool result is `isError: true` containing
  `URL_NOT_ALLOWED`
- **AND** the rejection reason names the project-suffix mismatch
- **AND** no chromium process is spawned

#### Scenario: Loopback IP literal is rejected

- **WHEN** an agent calls
  `browser.open({ url: "http://127.0.0.1:8080/" })` or
  `browser.open({ url: "http://[::1]:8080/" })`
- **THEN** the tool result is `isError: true` containing
  `URL_NOT_ALLOWED`
- **AND** no chromium process is spawned

#### Scenario: Allowlisted sibling service opens normally

- **WHEN** an agent in project `acme` calls
  `browser.open({ url: "http://web.acme.localhost:8080/" })`
- **THEN** the tool result is `{ window_id: "win-<uuid>" }` (no
  `isError`)
- **AND** a chromium process spawns with `--app=http://web.acme.localhost:8080/`
- **AND** the `WindowRegistry` contains the new entry

#### Scenario: URL with userinfo is rejected

- **WHEN** an agent calls
  `browser.open({ url: "http://user:pass@web.acme.localhost:8080/" })`
- **THEN** the tool result is `isError: true` containing
  `URL_NOT_ALLOWED`
- **AND** the rejection reason names the `userinfo` rule

### Requirement: Authorisation by Unix-socket peer credential

The tray SHALL authorise every MCP session by Unix-socket peer
credential at first-`McpFrame` time. When a forge container connects to
the control socket and sends its first `McpFrame`, the tray SHALL look
up the connecting peer's PID via `SO_PEERCRED` (Linux) or the
platform-equivalent peer-credential API.
The PID SHALL be matched against the tray's
`PeerPid → ProjectLabel` table populated at forge spawn time. If the
PID is not found in the table, the connection SHALL be closed
immediately with `Error { code: UnauthorisedPeer }` and an
accountability log entry recording the rejection.

The MCP session's bound project label SHALL be the value resolved from
the table. The agent SHALL NOT supply the project label in any tool
input; the URL allowlist requirement above MUST consult only the
peer-derived label.

`SO_PEERCRED` returns a snapshot at `connect(2)` time; PID reuse is
considered out of scope (requires same-UID attacker who already has
host access).

`TODO: verify` Windows Named Pipe peer-credential semantics
(`GetNamedPipeClientProcessId` and the trust model around it) — flagged
under Open Question Q-OPEN-3 in `design.md`.

@trace spec:host-browser-mcp, spec:tray-host-control-socket

#### Scenario: Peer-PID maps to project label

- **WHEN** the tray spawns forge container `acme-aeranthos` with
  PID 1234
- **AND** the forge stub from inside that container connects to the
  control socket
- **THEN** `SO_PEERCRED` returns PID 1234
- **AND** the `PeerPid → ProjectLabel` table maps 1234 to `acme`
- **AND** the MCP session's bound project label is `acme`
- **AND** subsequent `browser.open` allowlist checks use `acme`

#### Scenario: Unknown peer PID is rejected

- **WHEN** an arbitrary process on the same UID connects to the control
  socket and sends an `McpFrame`
- **AND** its PID is not present in the tray's spawn table
- **THEN** the tray sends `Error { code: UnauthorisedPeer }`
- **AND** closes the connection
- **AND** logs the rejection with `category = "browser-mcp"`,
  `outcome = "unauthorised-peer"`,
  `peer_pid = <pid>`

### Requirement: Per-(project,host) debounce on browser.open

The MCP server SHALL maintain an in-memory `(project_label, host) →
Instant` table of the last successful `browser.open` per
`(project, host)` tuple. If a fresh `browser.open` arrives for the same
tuple within 1000 ms of the previous successful open, the server SHALL
return the existing `window_id` without spawning a second chromium
process: `{ window_id: <existing>, debounced: true }`.

Debounce SHALL key on `(project, host)` only — path and query SHALL NOT
participate, so an agent looping retries on the same host gets a
stable window. The 1000 ms window matches the proposal's debounce
note.

@trace spec:host-browser-mcp

#### Scenario: Rapid duplicate open returns existing window

- **WHEN** an agent calls `browser.open({ url: "http://web.acme.localhost:8080/foo" })`
  at t=0 and the call succeeds with `window_id = win-A`
- **AND** the agent calls `browser.open({ url: "http://web.acme.localhost:8080/bar" })`
  at t=200 ms (different path, same host)
- **THEN** the second call returns
  `{ window_id: "win-A", debounced: true }`
- **AND** no second chromium process is spawned
- **AND** an accountability log entry records the debounce

#### Scenario: Open after debounce window spawns new window

- **WHEN** an agent's first `browser.open` for `(acme, web.acme.localhost)`
  succeeded 1500 ms ago
- **AND** the agent calls `browser.open` for the same host again
- **THEN** a fresh chromium process is spawned
- **AND** a new `window_id` is returned
- **AND** the `WindowRegistry` now has two entries for the host

### Requirement: browser.eval is disabled by default in v1

In the v1 release, `browser.eval` SHALL appear in `tools/list` but
every `tools/call` invocation SHALL return
`{ isError: true, content: [{ type: "text", text: "EVAL_DISABLED: browser.eval is disabled in v1; see follow-up change" }] }`.
The expression SHALL NOT be sent to CDP.

A follow-up change (tracked under Open Question Q-OPEN-1 in
`design.md`) SHALL introduce a per-project opt-in mechanism. Until that
change ships, no UX surface SHALL be added — per the project's
"no unauthorised UX" rule.

@trace spec:host-browser-mcp

#### Scenario: browser.eval call returns EVAL_DISABLED

- **WHEN** an agent calls
  `browser.eval({ window_id: "win-A", expression: "1+1" })`
- **THEN** the tool result is `isError: true` containing
  `EVAL_DISABLED`
- **AND** no CDP `Runtime.evaluate` call is sent

#### Scenario: browser.eval is still listed for discoverability

- **WHEN** an agent calls `tools/list`
- **THEN** the result includes a `browser.eval` entry with its
  description noting it is currently disabled

### Requirement: CDP method usage is pinned to stable 1.3 and the bundled-Chromium version

The MCP server's CDP client SHALL use ONLY methods available in CDP
stable channel 1.3 and SHALL pin the exact wire shape (parameter set,
field names) per the bundled-Chromium version shipped by
`host-chromium-on-demand`. The methods used by v1 are:

- `Target.getTargets`, `Target.attachToTarget` — discover and attach to
  the window's target
- `Page.navigate` — used internally by `browser.open` ordering when
  the cookie-injection sibling capability runs
- `Page.getNavigationHistory` — backs `browser.read_url`
- `Page.captureScreenshot` — backs `browser.screenshot`
- `Runtime.evaluate` — backs `browser.click` (synthetic click via
  `element.click()`), `browser.type` (sets `value` + dispatches
  `input` event), and (when later enabled) `browser.eval`

A Chromium version bump in `host-chromium-on-demand` SHALL trigger a
refresh of the `cheatsheets/web/cdp.md` pinned method matrix and a
re-run of the integration test suite before the new image ships.

@trace spec:host-browser-mcp, spec:host-chromium-on-demand

#### Scenario: CDP method matrix is verifiable against upstream docs

- **WHEN** the v1 implementation is reviewed against
  `https://chromedevtools.github.io/devtools-protocol/1-3/`
- **THEN** every CDP method named above is present in the stable 1.3
  domain index
- **AND** the parameter shapes used in the implementation match the
  stable 1.3 schema

### Requirement: Per-call accountability log with redacted payloads

Every `tools/call` invocation SHALL emit exactly one accountability log
entry at level `info` with the following fields:

- `category = "browser-mcp"`
- `spec = "host-browser-mcp"`
- `cheatsheet = "web/cdp.md"` (or `web/mcp.md` for transport-layer
  events)
- `tool = "<tool name>"`
- `project = "<peer-derived project label>"`
- `outcome = "ok" | "denied" | "error" | "debounced"`
- `window_id = "<id or null>"`
- For `browser.open`: `host = "<hostname>"` (no path, no query)
- For `browser.eval`: `expression_sha256 = "<hex>"` instead of the
  expression
- For `browser.type`: `selector = "<selector>"` and
  `text_len = <usize>` instead of the text

Payload values that could carry secrets (`browser.eval` expression,
`browser.type` text, `browser.screenshot` PNG bytes) SHALL NEVER appear
in any log entry — they are hashed, length-truncated, or omitted per
the rules above.

@trace spec:host-browser-mcp, spec:logging-accountability

#### Scenario: browser.open log entry contains host but not query

- **WHEN** an agent calls
  `browser.open({ url: "http://web.acme.localhost:8080/foo?secret=xyz" })`
- **THEN** the audit log line contains `host = "web.acme.localhost"`
- **AND** does NOT contain the substring `secret=xyz`
- **AND** does NOT contain the path `/foo`

#### Scenario: browser.type log redacts text content

- **WHEN** an agent calls
  `browser.type({ window_id, selector: "#password", text: "hunter2" })`
- **THEN** the audit log line contains `selector = "#password"` and
  `text_len = 7`
- **AND** does NOT contain the substring `hunter2`

### Requirement: Per-message size cap and DoS protection

The `McpFrame` envelope payload SHALL be capped at 4 MiB
(`4 * 1024 * 1024` bytes). A frame larger than the cap SHALL be
rejected with `Error { code: PayloadTooLarge }` on the control socket
and SHALL close the connection. The cap is sized to comfortably hold a
2 MiB base64-encoded full-page screenshot plus JSON-RPC envelope
overhead.

The MCP server SHALL enforce a per-session in-flight tool-call budget
of 16 concurrent calls; the 17th `tools/call` SHALL be rejected with a
JSON-RPC error until at least one of the 16 completes.

`TODO: verify` whether `tray-host-control-socket`'s existing 64 KiB
per-message cap subsumes or conflicts with this 4 MiB cap. If it
conflicts, this spec's cap MUST win for `McpFrame` (only) via a
per-variant override; if the existing cap already permits 4 MiB for
`McpFrame`-tagged frames, no change is needed. Flagged under design.md
risk note.

@trace spec:host-browser-mcp, spec:tray-host-control-socket

#### Scenario: Oversized McpFrame closes the connection

- **WHEN** a forge stub sends an `McpFrame` whose payload exceeds 4 MiB
- **THEN** the tray sends `Error { code: PayloadTooLarge }`
- **AND** closes the control-socket connection
- **AND** all `WindowRegistry` entries for that session are retained
  (windows survive — see window-survival requirement)

#### Scenario: Concurrent-call cap rejects 17th in-flight call

- **WHEN** 16 `tools/call` invocations are already in flight on a
  single MCP session
- **AND** a 17th `tools/call` arrives
- **THEN** the server replies with JSON-RPC error
  `-32000 ConcurrentCallLimit`
- **AND** the 16 in-flight calls continue to completion unaffected


## Sources of Truth

- `cheatsheets/runtime/chromium-isolation.md` — Chromium Isolation reference and patterns
- `cheatsheets/web/cdp.md` — Cdp reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:host-browser-mcp" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
