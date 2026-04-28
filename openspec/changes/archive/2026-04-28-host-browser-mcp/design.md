# Design — host-browser-mcp

## Context

Forge containers run AI agents (`claude`, `opencode`) with **zero credentials and
zero external network access** (per `enclave-network` and `forge-offline`). For
agentic web-app testing — Flutter web smoke tests, opencode-web inspection,
visual regression of a project's `web.<project>.localhost:8080` service — those
agents need a way to drive a real, GPU-accelerated, host-rendered browser
window. Three failed alternatives motivate the host-side MCP path:

1. **Browser inside the forge** (`forge-headless-browsers`): chromium-headless
   plus chromedriver/geckodriver are already baked, but they have no display,
   no clipboard, no host-side cookies, and most importantly, no way to expose
   what the agent is *seeing* back to the user. They are correct for unit /
   integration test runs, wrong for "show me what the page looks like".
2. **Spawn a host browser via shelling out**: requires the forge to reach the
   host filesystem / the host's `xdg-open`. Crosses the enclave boundary
   gratuitously and gives the agent an arbitrary-process-launch primitive.
3. **Direct CDP from inside the forge** to a host-launched Chromium: needs
   either an open CDP port reachable from the forge network (security
   regression) or a TCP forward through the enclave (complex, easy to misuse).

The locked solution is a **host-resident MCP server** (`tillandsias-browser-mcp`,
Rust binary) that:

- Owns the only CDP connection to bundled Chromium windows launched by the tray
  via `host-chromium-on-demand`.
- Exposes a narrow tool surface (`browser.open`, `browser.screenshot`,
  `browser.click`, `browser.type`, `browser.eval`, `browser.read_url`,
  `browser.list_windows`, `browser.close`) over MCP stdio JSON-RPC.
- Bridges that stdio transport across the enclave boundary by piping it
  through the existing `tray-host-control-socket` Unix socket — no new socket,
  no new attack surface.
- Enforces a per-project allowlist that **rejects** the agent's own UI host
  (`opencode.<project>.localhost`) and any non-loopback URL.

The forge-side stub is a tiny shell script registered in
`~/.config-overlay/opencode/config.json` (and the equivalent claude config) that
proxies stdio to the host control socket. The agent sees a normal MCP server;
the host sees one well-typed channel; the cross-enclave seam is the same
`/run/user/<uid>/tillandsias/control.sock` already justified by
`tray-host-control-socket` and `opencode-web-session-otp`.

## Goals / Non-Goals

**Goals:**

- Agents in the forge can request a **named browser window** for a sibling
  project URL (e.g. `web.thinking-service.localhost:8080`), drive it via CDP,
  and read back screenshots and DOM state — without leaving the enclave or
  acquiring any host credentials.
- The MCP server SHALL refuse to open `opencode.<project>.localhost` (the
  agent's own UI), any non-`*.<project>.localhost:8080` URL, and any URL
  whose `<project>` does not match the forge container's project label.
- Window lifetime is independent of the MCP call — a window opened by
  `browser.open` survives MCP disconnects so the user can keep interacting
  with it after the agent finishes its task.
- All eight v1 tools complete in <2 s under normal conditions; screenshots in
  <500 ms once the page is loaded.
- Every tool invocation emits an accountability log entry with project label,
  tool name, target URL or window id, and success/failure — values that
  would expose secrets are redacted.
- Cross-OS surface is **Linux first, macOS second, Windows third**. The MCP
  protocol layer is portable; only the chromium launch path
  (`host-chromium-on-demand`) is per-OS.

**Non-Goals:**

- Driving the user's daily browser (system Chrome / Safari / Firefox /
  Edge). Per `host-chromium-on-demand` Decision: the only browser the tray
  ever launches is the bundled Chromium in `~/.cache/tillandsias/chromium/`.
  Adding system-browser fallback would re-introduce the privacy gap that
  `host-chromium-on-demand` was created to close.
- Persisting browser windows across tray restarts. The MCP server lives as
  long as the tray; quit the tray, lose the windows.
- A "headless mode" tool. Agents that need true headless go via the
  forge-side `chromium-headless` binary baked by `forge-headless-browsers`.
  This MCP is for visible, GPU-accelerated, user-observable windows.
- Cross-project window sharing. Project A's forge cannot open or inspect
  windows opened on behalf of project B's forge; the per-attach OTP from
  `opencode-web-session-otp` keys windows to the issuing project.
- Network request interception / mocking (CDP `Network.requestWillBeSent`
  capture is in scope; full Fetch domain interception is not).
- File-upload / `<input type="file">` automation (CDP `Page.setFileInputFiles`
  is out of scope for v1; raises file-system reach concerns the allowlist
  cannot easily express).

## Decisions

### Decision 1 (Q1) — Transport: extend `tray-host-control-socket`, no new socket

**Choice**: The MCP stdio JSON-RPC stream is **encapsulated inside** a new
postcard envelope variant on the existing Unix control socket
`/run/user/<uid>/tillandsias/control.sock`. The forge-side shell stub
`mcp/host-browser.sh` reads JSON-RPC frames from stdin, wraps each as
`ControlMessage::McpFrame { session_id, payload: Vec<u8> }`, writes the
length-prefixed postcard envelope to the socket, and reads response
envelopes off the socket back to stdout.

**Why**:

- The socket already has the correct security properties: mode `0600`, owned
  by the tray user, in the per-user XDG runtime dir. Adding a *second*
  socket doubles the attack surface for the same trust boundary.
- The socket already has a typed enum (`ControlMessage`) with an existing
  variant (`IssueWebSession`) and unknown-variant rejection at deserialise
  time. Adding `McpFrame` keeps the dispatch matrix in one place.
- The "no JSON in hot paths" rule (`feedback_design_philosophy`) still
  holds: the JSON-RPC payload is a `Vec<u8>` blob inside a postcard
  envelope. Postcard handles framing and routing; the JSON is opaque to the
  socket layer and only parsed by the MCP server in-process.
- The MCP server runs in the tray process (or as a tray-spawned thread) and
  consumes the `McpFrame` channel. Per-session state (window registry,
  CDP connections) lives in tray-process memory.

**Rejected alternative — dedicated MCP socket** (e.g.
`/run/user/<uid>/tillandsias/mcp.sock`): doubles socket lifecycle code (start,
stop, stale-detect), doubles permission audit surface, requires its own
client-library, and offers no isolation benefit since both sockets are
owned by the same tray process anyway.

**Rejected alternative — TCP loopback** (e.g. `127.0.0.1:<random>`): every
process on the host could connect; no peer-credential check on Linux means
authentication would have to be per-connection token (Bearer/cookie). The
Unix-socket peer credential (`SO_PEERCRED`) lets the tray reject non-tray-spawned
connections without a token at all.

**Rejected alternative — D-Bus session bus**: requires session-bus availability
inside the forge container (it doesn't have one — the enclave is namespaced
away from the host session bus). Bridging would require yet another helper.

### Decision 2 (Q2) — Browser provider precedence: bundled Chromium only

**Choice**: The MCP server uses **only** the bundled Chromium binary at
`~/.cache/tillandsias/chromium/<version>/chrome` provisioned by
`host-chromium-on-demand`. If the binary is missing the MCP server replies
to every `browser.*` tool call with a structured error
(`{ code: "BROWSER_UNAVAILABLE", message: "bundled chromium not yet downloaded" }`),
and emits an accountability log entry. No fallback to system Chrome / Safari
/ Firefox / Edge.

**Why**: `host-chromium-on-demand` already settled the privacy/isolation case
for "no shared state with the user's daily browser". Using a system browser
here would (a) mix the agent's CDP control with the user's open Gmail tab
(catastrophic), (b) surface different CDP versions per OS (CDP is stable but
Safari has its own protocol), (c) break the "incognito + ephemeral
user-data-dir" guarantee. Bundled Chromium is the single, predictable,
isolated target.

**Rejected alternative — system Chrome / Chromium / Edge fallback**: see above;
mixes daily-browsing state with agent-driven state. Not acceptable.

**Rejected alternative — Safari (macOS)**: Safari uses the WebKit Inspector
Protocol, not CDP. Different tool semantics, different RPC shape, would
need a per-platform abstraction over both. v1 ships CDP-only via bundled
Chromium on all three OSes.

**Rejected alternative — Firefox CDP shim**: Firefox supports a partial CDP
via the Marionette adapter, but coverage is limited (no `Network.setCookies`
parity for some attribute combinations, intermittent breakage). Bundled
Chromium is more reliable.

### Decision 3 (Q3) — Window model: one Chromium **process per window**, MCP tracks by `window_id`

**Choice**: Each `browser.open(url)` call spawns a **new bundled-Chromium
process** with a fresh ephemeral `--user-data-dir`, `--incognito`,
`--remote-debugging-port=<random>`, and `--app=<url>`. The MCP server attaches
CDP, captures the first target id, and returns a stable `window_id` (e.g.
`win-<uuid-v4>`) to the agent. Subsequent calls (`screenshot`, `click`, ...)
are routed to that window via its `(pid, cdp_port, target_id)` tuple held in
the in-process `WindowRegistry`.

**Why**:

- Process-per-window is the same model `host-chromium-on-demand` uses for
  user-facing attach windows; reusing the launch primitive avoids divergent
  lifecycle code.
- Process isolation: a wedged renderer in window A cannot affect window B.
  Single-process-multi-target via CDP `Target.createTarget` would couple
  them.
- Ephemeral `--user-data-dir` per window means cookies / localStorage / IndexedDB
  do not leak from one window to another, even within the same MCP session.
- Window survives MCP-channel drop: if the agent disconnects, the window
  stays open until the user closes it OR the tray is quit OR
  `browser.close(window_id)` is called. The window registry holds a strong
  reference to the process handle; orphan reaping happens on tray Quit per
  `shutdown-conmon-stragglers`-style cleanup.

**Rejected alternative — single Chromium process, multiple targets via
`Target.createTarget`**: smaller resource footprint (~80 MB shared) but a
crash in one renderer can take down all targets; harder to guarantee
ephemeral profile per window.

**Rejected alternative — single tab in single window**: Chromium with `--app`
naturally opens one tab per window, which is what we want; no need to
multiplex.

### Decision 4 (Q4) — Cross-OS: **same MCP surface, per-OS launcher only**

**Choice**: The MCP server, allowlist enforcement, CDP client, and tool
dispatch are 100% portable Rust (`tokio`, `serde_json`, `postcard`). The
**only** per-OS path is the chromium launch helper from
`host-chromium-on-demand` — which already abstracts the binary location and
spawn flags per OS. macOS uses the same Chrome for Testing binary
(`googlechromelabs.github.io/chrome-for-testing/`); Windows uses the
`chrome.exe` from the same channel. Safari, Edge, Firefox are not used on
any OS.

**Why**: CDP is identical across Chrome for Testing builds on Linux / macOS
/ Windows. The Unix control socket is replaced on Windows by a Named Pipe
(per the `tray-host-control-socket` change's cross-platform note —
TODO: verify the change explicitly addresses Windows; if not, the Windows
port of the control socket capability will be a sibling change). The MCP
protocol layer does not care.

**Risk noted**: Windows pipe semantics differ from Unix domain sockets in
peer-credential discovery — `GetNamedPipeClientProcessId` exists but the
authorisation model is more complex than `SO_PEERCRED`. Windows
implementation of the control socket (out of scope for this change) MUST
solve this before this change is usable on Windows.

`TODO: verify` whether `tray-host-control-socket` already plans the Windows
Named Pipe equivalent, or whether a separate change is required to track it.

### Decision 5 (Q5) — Allowlist: hostname suffix `<project>.localhost:8080`, **deny `opencode.<project>.localhost`**, deny everything else

**Choice**: `browser.open(url)` parses the URL with `url::Url`. Accept iff:

1. Scheme is exactly `http` or `https`.
2. Host parses to a domain name (NOT an IP literal — no `127.0.0.1`, no
   `[::1]`, no public IPs, no `localhost` bare).
3. Host ends in `.<project>.localhost` where `<project>` matches the
   forge container's project label exactly. The project label is bound to
   the MCP session at the time the host MCP server accepts the
   `ControlMessage::McpFrame` from the forge — see Decision 6 below.
4. Host does NOT begin with `opencode.` — that is the agent's own UI per
   the proposal's critical rule.
5. Port is exactly `8080` (the host-side router publish port per
   `opencode-web-session`).
6. URL contains no userinfo (`user:pass@host` form).

Any other URL → reject with `{ code: "URL_NOT_ALLOWED", message: "<reason>" }`
and an accountability log entry.

**Why** each rule:

- Loopback-only: prevents the agent from driving an arbitrary internet site
  via the user's own browser session — a credential-exfiltration vector.
- `<project>.localhost:8080` suffix: confines the agent to the same project's
  router-fronted services. The router (per `opencode-web-session-otp`) is
  the only thing listening on `:8080`; anything else is unreachable.
- Deny `opencode.`: the agent can open `web.`, `api.`, `db.`, etc. of its
  own project, but cannot open or inspect its own UI host. This blocks the
  "agent looks at its own conversation history" footgun and the related
  "agent reads the OTP cookie of its own session" attack.
- Deny IP literals + bare `localhost`: forces the URL through the project's
  hostname namespace. `127.0.0.1:8080/`, `localhost:8080/` would bypass the
  per-project subdomain check entirely.
- Port pin to `8080`: the only port the router publishes. Prevents the
  agent from hitting random other listeners on the host.
- No userinfo: HTTP basic auth in the URL is a credential-exfiltration vector.

**Rejected alternative — wildcard allow with a denylist**: every new attack
vector requires a denylist update. Allowlist is the correct shape here.

**Rejected alternative — let the agent supply any URL, sandbox via
`--user-data-dir` only**: the agent has *intent*; the sandbox prevents
*persistence*. A non-allowlisted URL with a sandbox still drives the agent's
exfiltration plan, just without leaving cookies behind.

### Decision 6 (Q6) — Auth: project label bound at socket-accept time, no per-call token

**Choice**: When the forge's stdio-stub connects to the host control socket,
the host reads the connecting peer's PID via `SO_PEERCRED` (Linux) or the
Named-Pipe equivalent (Windows). The tray maintains a lookup table
`PeerPid → ProjectLabel` populated at forge spawn time (the tray launches
the forge container, so it knows the container's PID and the project it was
spawned for). The MCP session inherits the project label of the connecting
peer. Every `browser.open` allowlist check uses *that* label, not a label the
forge agent supplies.

If `SO_PEERCRED` resolves to a PID not in the table, the connection is
rejected with `{ code: "UNAUTHORISED_PEER", ... }` and an accountability
log entry.

**Why**:

- **No agent-supplied auth**: the agent cannot lie about which project it
  belongs to because the project comes from the OS-level peer credential,
  not from the message payload. This is the same trust model as
  `SO_PEERCRED` for X11 sockets and the Wayland compositor.
- **No token to manage**: per-call tokens require a token-issue flow,
  rotation, expiry, leakage handling. Peer-credential is stateless.
- **Consistent with `tray-host-control-socket`'s mode-`0600` model**: the
  socket file is reachable only by the same UID; the peer-PID lookup
  refines that to "only by tray-spawned processes".

**Rejected alternative — per-attach OTP from
`opencode-web-session-otp`**: that OTP is for *browser* authentication to
the router; reusing it for forge→tray MCP authentication would couple two
unrelated channels and require the forge to know the OTP (it doesn't,
deliberately).

**Rejected alternative — per-container token baked at spawn time**: tray
generates a token, injects via env var, forge sends it on each MCP message.
Functionally equivalent to peer-credential but adds a secret-handling
surface for no security gain. Peer-credential is simpler and stronger.

### Decision 7 (Q7) — v1 MCP tool surface (eight tools)

**Choice** — the v1 tool list is locked at:

| Tool | Inputs | Output | Notes |
|---|---|---|---|
| `browser.open` | `{ url: string }` | `{ window_id: string }` | Allowlist-gated. New process. |
| `browser.list_windows` | `{}` | `{ windows: [{ window_id, url, title }, ...] }` | Only windows opened by THIS MCP session. |
| `browser.read_url` | `{ window_id: string }` | `{ url: string, title: string }` | Live values via CDP `Page.getNavigationHistory`. |
| `browser.screenshot` | `{ window_id: string, full_page?: boolean }` | `{ png_base64: string, width: u32, height: u32 }` | CDP `Page.captureScreenshot`. PNG only. |
| `browser.click` | `{ window_id, selector }` | `{ ok: bool }` | CDP `Runtime.evaluate` finds element, dispatches synthetic click. |
| `browser.type` | `{ window_id, selector, text }` | `{ ok: bool }` | Sets `value` + dispatches `input` event. No raw key dispatch in v1. |
| `browser.eval` | `{ window_id, expression }` | `{ result: serde_json::Value }` | CDP `Runtime.evaluate`. Result truncated at 64 KB. **Disabled by default; user opts in per project via tray menu (`TODO: verify` whether the menu lives in this change or a follow-up — flagged in Open Questions).** |
| `browser.close` | `{ window_id }` | `{ ok: bool }` | Terminates the chromium process; removes from registry. |

**Why this surface and not more / fewer**:

- Five "read" or "navigate" tools cover the vast majority of agentic
  testing: open a page, list/read what's there, click and type to interact,
  screenshot the result.
- `browser.eval` is the universal escape hatch — anything CDP can do on the
  Runtime domain becomes reachable. Gating it behind opt-in keeps the
  attack surface narrow by default.
- Excluded for v1: `browser.tail_console` (CDP `Console.messageAdded` is a
  push event; the MCP stdio model is request/response — needs a streaming
  story we don't yet have), `browser.network_log` (same reason),
  `browser.upload_file` (file-system reach via `Page.setFileInputFiles` is
  out of scope per Non-Goals).

**Rejected alternative — bigger surface from the start** (15+ tools): MCP
tool inflation makes the client-side prompt inject huge tool descriptions
and confuses the agent's tool selection. Keep v1 lean.

**Rejected alternative — generic `cdp.send_command(method, params)` tool**:
exposes the entire CDP protocol with no allowlist. Unbounded. Rejected for
the same reason `browser.eval` is opt-in: agentic tools without a tight
contract are agentic footguns.

### Decision 8 (Q8) — Debounce: per `(project, host)`, 1000 ms window, NO per-window-id check

**Choice**: `browser.open` maintains an in-memory `(project, host) → Instant`
table. If the same project tries to open the same host within 1000 ms of a
prior successful `browser.open`, the second call returns
`{ code: "DEBOUNCED", existing_window_id: <previous> }` instead of opening a
second window. The 1000 ms window matches the proposal's debounce note.

**Why**: agents loop; Claude or OpenCode under a "verify the page renders"
prompt frequently retries `browser.open` 3-4 times in <100 ms. Without
debounce the user gets a window storm. Returning the existing window id is
useful: the agent's next `browser.screenshot` still works on the
already-open window.

**Why not include path / query in the key**: a debounced `browser.open` is
"probably the same page rendering"; an agent that wants to navigate to a
different URL on the same host should call `browser.eval window_id
"location.href = '<new>'"` after opening once.

### Decision 9 (Q9) — Forge-side stub: shell script, no new binary

**Choice**: A new shell script `images/default/config-overlay/mcp/host-browser.sh`
proxies stdio to the host control socket via `socat` (already in the forge
image — `TODO: verify` it's actually present, fall back to a minimal
`nc-unix` if not). The script reads JSON-RPC frames from stdin, length-prefixes
each, prepends the postcard `McpFrame` discriminator, and forwards. Reverse
direction unwraps and writes JSON-RPC to stdout.

**Why**: keeps the forge-side surface tiny and matches the existing
`git-tools.sh` / `project-info.sh` pattern in `config-overlay/mcp/`. Adding
a Rust binary just for stdio↔socket bridging would mean another build
artefact, another signing step, another size hit on the forge image.

**Risk**: the postcard framing is now done in shell — fragile. Mitigation:
the host side is the source of truth for framing; a malformed frame from
shell results in a `deserialise-fail` log entry and the connection is
dropped, never a security incident. The agent's MCP client will see an
error and either retry or surface to the user.

`TODO: verify`: actually `socat` and `printf` length-prefix tricks work for
the postcard wire format at scale. If shell turns out to be too brittle a
follow-up change will replace `host-browser.sh` with a tiny Rust binary
shipped inside the forge image (~200 KB).

## Risks / Trade-offs

- **CDP version drift**: Chrome for Testing pins a specific CDP revision per
  major. A Chromium bump in `host-chromium-on-demand` could change the shape
  of `Network.setCookies` or `Page.captureScreenshot`. Mitigation: pin the
  CDP client to the version matrix the cheatsheet lists (`cheatsheets/web/cdp.md`,
  introduced by this change), refresh on each Chromium bump.
- **`browser.eval` is the loaded gun**: even gated behind opt-in, it lets the
  agent execute arbitrary JS in the loaded page's origin. Mitigation: the
  per-project opt-in is explicit; the loaded page is always
  `*.<project>.localhost:8080` (allowlist guarantees), so the worst case is
  the agent script-kiddying its own project's web service. Threat is
  bounded by the allowlist.
- **Debounce hides bugs**: if the agent legitimately wants two windows on the
  same host within 1 s, debounce breaks that. Mitigation: the agent can
  call `browser.list_windows` first to learn there is already one, or wait
  and retry. Unlikely to bite real workflows.
- **Window registry is in-tray-process memory**: tray crash / quit drops
  every window. Mitigation: documented in spec; the `host-chromium-on-demand`
  reaping path catches orphaned chromium processes on next tray start.
- **`SO_PEERCRED` returns a PID, not a stable identity**: a forge container
  exiting and a different process inheriting the PID could spoof. Mitigation:
  the `PeerPid → ProjectLabel` table is maintained synchronously with
  forge spawn / exit; on PID-not-found the connection is rejected. PID
  reuse races are nanoseconds-wide and require the attacker to already be on
  the same UID — outside the threat model.
- **MCP stdio framing inside postcard envelope means message size matters**:
  CDP screenshot responses are PNG-base64 ≈ 100s of KB. The postcard
  envelope length-prefix is `varint(usize)`; the control socket buffer must
  be sized accordingly. `TODO: verify` the existing `tray-host-control-socket`
  spec sets a max-frame-size (proposal says nothing); if not, this change's
  spec adds it (4 MB cap) to bound DoS.
- **Per-call accountability log is verbose**: the agent loops, the log fills.
  Mitigation: log lines are structured; users grep by `category="browser"`
  + `project=...`. Same pattern as router accountability logs.

## Open Questions

- **Q-OPEN-1 — `browser.eval` opt-in UX surface**: the menu / prompt that
  lets the user enable `browser.eval` per project. The "no unauthorized UX"
  rule (`feedback_no_unauthorized_ux`) means we cannot just add a menu item
  in this change; the user needs to explicitly approve the menu shape. v1
  ships with `browser.eval` permanently disabled; a follow-up change adds
  the opt-in.
- **Q-OPEN-2 — `console.log` / network-request streaming**: out of scope for
  v1, but agents will ask for it. A future change introduces an MCP-stream
  channel (long-lived) that complements the request/response tools.
- **Q-OPEN-3 — Windows Named Pipe peer-credential**: depends on the
  `tray-host-control-socket` capability landing the Windows port. `TODO:
  verify` whether that change's scope includes Windows or whether a sibling
  `tray-host-control-socket-windows` change is required.
- **Q-OPEN-4 — Forge-side stub: shell vs Rust binary**: shipping `socat` +
  `printf` framing is fragile but tiny. A 200 KB Rust binary is reliable
  but adds a build step. v1 starts with shell; if shell breaks we ship the
  binary in a follow-up.
- **Q-OPEN-5 — Tool list refinement after first user trial**: the v1
  surface is a guess at what agents will actually call. After 1-2 weeks of
  real usage we will know if `browser.click` is overused vs `browser.eval`
  is underused, etc.

## Sources of Truth

- Chrome DevTools Protocol stable docs:
  `https://chromedevtools.github.io/devtools-protocol/` (v1.3 stable channel)
  — wire format and method semantics for every CDP call this server makes.
- Model Context Protocol spec: `https://modelcontextprotocol.io/specification/`
  — JSON-RPC 2.0 framing, `initialize` / `tools/list` / `tools/call` /
  `prompts/list` / `resources/list` method shapes; matches the
  existing `git-tools.sh` reference impl.
- Chrome for Testing channel:
  `https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json`
  — pinned chromium binary used by `host-chromium-on-demand`.
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — the control
  socket lives in `/run/user/<uid>/`, ephemeral by design; the window
  registry is process memory only.
- `cheatsheets/runtime/forge-shared-cache-via-nix.md` — confirms MCP state
  has no shared-cache surface; the bundled chromium binary (which MCP
  consumes) lives in `~/.cache/tillandsias/chromium/` per
  `host-chromium-on-demand`.
- `cheatsheets/web/http.md` — URL parsing rules (scheme, host, userinfo,
  port) the allowlist enforces.
- (NEW, this change) `cheatsheets/web/cdp.md` — CDP method matrix this
  server uses; version-pinned per the Chromium release matrix; provenance
  to `chromedevtools.github.io/devtools-protocol/`.
- (NEW, this change) `cheatsheets/web/mcp.md` — MCP JSON-RPC framing
  reference; provenance to `modelcontextprotocol.io`.
- `openspec/changes/tray-host-control-socket/proposal.md` — the postcard
  envelope and socket contract this change extends with `McpFrame`.
- `openspec/changes/host-chromium-on-demand/proposal.md` — bundled Chromium
  binary and CDP-enabled launch this change consumes.
- `openspec/changes/opencode-web-session-otp/design.md` — sibling design
  for the per-window OTP that scopes browser sessions; same trust model
  applies to MCP windows.
- `openspec/changes/forge-headless-browsers/proposal.md` — the in-forge
  headless chromium that this change is *not* replacing (different use case).
