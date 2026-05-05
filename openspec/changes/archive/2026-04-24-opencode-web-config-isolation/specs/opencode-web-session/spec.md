## ADDED Requirements

### Requirement: Config overlay is applied at container start

The forge OpenCode Web entrypoint SHALL copy the host-mounted
`/home/forge/.config-overlay/opencode/config.json` to
`/home/forge/.config/opencode/config.json` and
`/home/forge/.config-overlay/opencode/tui.json` to
`/home/forge/.config/opencode/tui.json` before invoking `opencode serve`. This
ensures OpenCode reads the Tillandsias-provided config (enclave ollama
baseURL, MCP servers, instructions, dark theme) rather than the minimal stub
baked into the image at build time.

#### Scenario: Provider baseURL points to the enclave ollama
- **WHEN** the forge container starts and the entrypoint reaches the config-
  overlay step
- **THEN** `/home/forge/.config/opencode/config.json` contains
  `provider.ollama.options.baseURL` equal to `http://inference:11434/v1`
- **AND** a `GET http://127.0.0.1:<host_port>/config` request returns the
  same baseURL in the resolved provider config
- **AND** OpenCode routes ollama completions to the enclave inference
  container, not to `localhost:11434` inside the forge

#### Scenario: Config schema validates
- **WHEN** OpenCode loads the config at startup
- **THEN** the config passes schema validation (no "Configuration is
  invalid" error)
- **AND** the server transitions to listening on
  `0.0.0.0:4096` successfully
- **AND** `permission`, `instructions`, and `provider` fields conform to
  the published OpenCode schema at `https://opencode.ai/config.json`

### Requirement: Config is additive — all OpenCode defaults preserved

The overlay config SHALL NOT use `enabled_providers` or otherwise restrict
the set of providers OpenCode exposes. Every provider OpenCode ships with
(OpenCode Zen, OpenRouter, Helicone, Anthropic, OpenAI, Google, and every
other entry in OpenCode's default set) MUST remain available inside a
Tillandsias forge container. Tillandsias adds an `ollama` provider entry
pointing at the enclave inference container, in addition to — not instead
of — OpenCode's defaults.

#### Scenario: OpenCode Zen is reachable
- **WHEN** the UI queries `GET /config/providers`
- **THEN** the response contains the `opencode` provider entry with its
  default Zen models (e.g. `gpt-5-nano`, `minimax-m2.5-free`)
- **AND** the user can select a Zen model and send a prompt without
  configuration changes

#### Scenario: Ollama is ADDED, not substituted
- **WHEN** the UI queries `GET /config/providers`
- **THEN** the response contains both the default providers AND an
  `ollama` provider
- **AND** the ollama provider's `options.baseURL` is
  `"http://inference:11434/v1"`
- **AND** the ollama provider's `models` map includes the curated local
  model list (qwen2.5, qwen2.5-coder, llama3.2, etc.)

### Requirement: OpenCode state is seeded fresh per container start

The forge OpenCode Web entrypoint SHALL delete
`/home/forge/.local/share/opencode/` before invoking `opencode serve`. This
clears any stale project rows or session state from a prior run of the same
container (e.g. after a crash-restart), ensuring OpenCode's first request
creates exactly one project row — the mounted project — and no "global"
pseudo-project or orphan entries.

#### Scenario: Only the mounted project is visible on first load
- **WHEN** a fresh forge container starts and the webview loads
- **THEN** `GET /project` returns exactly one project entry
- **AND** that entry's `worktree` matches the mounted project directory
  (`/home/forge/src/<project>`)
- **AND** no entry with `id: "global"` or `worktree: "/"` is present

#### Scenario: Per-container isolation survives crashes
- **WHEN** an OpenCode Web container is force-killed mid-session and
  restarted by the tray
- **THEN** the new container starts with a fresh
  `/home/forge/.local/share/opencode/` directory
- **AND** no ghost projects from the prior run appear in the UI

### Requirement: Webview exposes devtools

The Tauri `WebviewWindow` created for an OpenCode Web session SHALL have
devtools enabled. The user MUST be able to open the inspector via the
platform's standard shortcut (F12 / Ctrl+Shift+I / right-click → Inspect).
This applies to both debug and release builds.

#### Scenario: Inspector opens via keyboard shortcut
- **WHEN** the user has an OpenCode Web window focused and presses F12 (or
  Ctrl+Shift+I on Linux/Windows, Cmd+Option+I on macOS)
- **THEN** the WebKit/WebView2 inspector opens in a panel
- **AND** the Network, Console, and Elements tabs are functional

#### Scenario: Devtools is not gated on build profile
- **WHEN** inspecting the `WebviewWindowBuilder` construction in
  `src-tauri/src/webview.rs`
- **THEN** `.devtools(true)` is called unconditionally (no
  `#[cfg(debug_assertions)]` gate and no runtime flag)

### Requirement: Each webview gets an isolated WebContext

Every `WebviewWindow` opened for an OpenCode Web session SHALL be constructed
with `.incognito(true)`. This gives each webview its own WebKit WebContext
with no shared cookies, localStorage, IndexedDB, or service-worker state.
Without isolation, opening a second project's webview (or re-opening one
after close) sees the prior session's cached client state and appears stuck
on the previous project.

#### Scenario: Two projects, two independent webviews
- **WHEN** the user attaches two different projects consecutively
- **THEN** each webview renders with empty localStorage
- **AND** neither webview's UI state bleeds into the other's routing or
  cached project selection
- **AND** closing one does not affect the other's in-flight session

### Requirement: Webview defaults to dark color scheme on first open

Every webview SHALL have an `initialization_script` that sets
`localStorage.opencode-color-scheme = "dark"` if not already present. Because
OpenCode's web UI uses a preload script
(`document.getElementById("oc-theme-preload-script")`) to pick the
`opencode-color-scheme` key from `localStorage` before paint, seeding the key
before page load ensures no flash of the system/light theme.

#### Scenario: First open renders dark immediately
- **WHEN** a fresh incognito webview loads
  `http://127.0.0.1:<port>/<base64(dir)>/`
- **THEN** the initialization script sets
  `opencode-color-scheme = "dark"` in localStorage before any other script
- **AND** OpenCode's preload script reads "dark" and paints the UI in the
  dark palette from the very first frame
- **AND** the user does not see a light-theme flash

#### Scenario: User override is respected
- **WHEN** the user manually switches to the light scheme via the UI toggle
  (which writes `opencode-color-scheme = "light"`)
- **AND** closes and re-opens the webview
- **THEN** because webviews are incognito (Decision: Requirement "Each
  webview gets an isolated WebContext"), the new webview starts fresh with
  the init script seeding "dark" again — the per-user choice is reset on
  every attach

### Requirement: Webview URL loads the project-scoped route directly

The webview URL SHALL be
`http://127.0.0.1:<host_port>/<base64url(project_dir)>/` where
`project_dir` is the container-internal project path
(`/home/forge/src/<project>`). Loading the directory-scoped route makes
OpenCode's frontend carry the directory context through every subsequent
API call (via `x-opencode-directory` header), which in turn makes
`InstanceMiddleware` register exactly the mounted project with OpenCode's
project table. Loading the bare `/` path causes a fallback through
`process.cwd()`-based discovery that may race with the startup-time
"global" pseudo-project registration.

#### Scenario: URL format includes base64url directory segment
- **WHEN** `open_web_session()` constructs the webview URL for a project
  named `myapp`
- **THEN** the URL is
  `http://127.0.0.1:<port>/L2hvbWUvZm9yZ2Uvc3JjL215YXBw/`
- **AND** the base64url encoding uses the URL-safe alphabet (`+` → `-`,
  `/` → `_`, no padding), matching the SolidJS `base64Encode` helper
  OpenCode uses for its `/:dir` route

#### Scenario: Mounted project is registered, empty repos still show "global"
- **WHEN** a project with at least one commit is mounted and the webview
  opens via the directory-scoped URL
- **THEN** `GET /project` returns a row for `/home/forge/src/<project>`
- **AND** that row becomes the active project in the UI
- **AND** an accompanying "global" row may still be present (upstream
  OpenCode behaviour when requests arrive without a directory hint) but
  does NOT become the default selection

#### Scenario: Repos without commits fall back to global projectID
- **WHEN** the mounted project is a fresh `git clone` with no commits yet
- **THEN** OpenCode's project discovery cannot resolve a tip and the
  session's `projectID` is `"global"`
- **AND** this is a known upstream limitation; it resolves itself once the
  user makes a first commit

### Requirement: extract_config_overlay preserves the directory inode

`extract_config_overlay` MUST write config files in place without removing
and recreating the host-side directory. Running forge containers bind-mount
`/run/user/<uid>/tillandsias/config-overlay` into `/home/forge/.config-overlay`.
If a subsequent tray action (e.g. another Attach Here) calls
`extract_config_overlay` with `remove_dir_all` + recreate, the old directory
inode is discarded and the running container's mount becomes an orphan
"deleted" entry — the mount point appears empty, MCP scripts vanish,
OpenCode's MCP client hangs waiting for `prompts/list` responses, and the
webview UI freezes on its first `/command` fetch.

#### Scenario: Concurrent attaches don't invalidate existing mounts
- **WHEN** user attaches project A, then (with project A's forge still
  running) attaches project B
- **THEN** extracting the config overlay for project B reuses the existing
  directory inode
- **AND** project A's container continues to see the MCP scripts,
  opencode config, and tui config as before
- **AND** no `//deleted` orphan mount appears in either container's
  `/proc/self/mountinfo`

### Requirement: MCP stdio servers respond to every standard method

Tillandsias-shipped MCP server scripts (`git-tools.sh`, `project-info.sh`, and any future MCPs) MUST respond to every MCP method OpenCode issues during normal operation — including `initialize`, `tools/list`, `tools/call`, `prompts/list`, `resources/list`, and `resources/templates/list`. Methods with no results SHALL return an empty-list result, not stay silent. Unknown methods SHALL return a JSON-RPC `-32601 Method not found` error with the request id.

#### Scenario: prompts/list returns empty list
- **WHEN** OpenCode queries an MCP server's `prompts/list`
- **THEN** the server responds with
  `{"jsonrpc":"2.0","id":<id>,"result":{"prompts":[]}}`
- **AND** no response takes longer than 100ms
- **AND** the UI's `/command` endpoint completes in under a second

#### Scenario: silent method handling is forbidden
- **WHEN** OpenCode calls any JSON-RPC method on our MCP server
- **THEN** the server emits exactly one JSON-RPC response line per request
- **AND** no request results in the 60s MCP client timeout
  (`MCP error -32001: Request timed out`)

### Requirement: SSE-keepalive proxy injects CSP hashes for inline scripts

The `sse-keepalive-proxy` fronting `opencode serve` SHALL rewrite the
upstream `Content-Security-Policy` header on every HTML response to add
`'sha256-<digest>'` entries to the `script-src` directive — one per inline
`<script>` tag in the body. The proxy SHALL compute each digest dynamically
on every request (no hardcoded hash) so the fix survives opencode version
upgrades that change the inline script content.

**Context:** OpenCode's embedded web UI ships a `DEFAULT_CSP` header
(`default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; …`) AND an
inline `<script id="oc-theme-preload-script">`. The CSP blocks the inline
script; the UI's theme initialization fails and users see CSP violation
errors in the browser console. Upstream tracked at
[anomalyco/opencode#21088](https://github.com/anomalyco/opencode/issues/21088);
fix exists in PR #21089 but was auto-closed on template non-compliance.
The canonical fix per CSP Level 3 is to move inline scripts to external
files. Until upstream ships that, we hash them in place — the same approach
opencode takes on its proxied path at `app.opencode.ai`. We explicitly do
NOT add `'unsafe-inline'` (CSP3 + OWASP both say that's the worst option).

#### Scenario: Inline theme preload is allowed after proxy rewrite
- **WHEN** a browser fetches `/` or any base64url-directory-scoped route
- **THEN** the response's `Content-Security-Policy` contains a `sha256-…`
  entry in `script-src` matching the digest of the
  `<script id="oc-theme-preload-script">` body
- **AND** the browser executes the inline script without CSP violations
- **AND** `document.documentElement.dataset.colorScheme` is set by the
  preload script on first paint

#### Scenario: Hashes are computed dynamically, not hardcoded
- **WHEN** auditing `sse-keepalive-proxy.js`
- **THEN** the proxy computes each script's sha256 via
  `crypto.createHash('sha256').update(body, 'utf8').digest('base64')` at
  response time
- **AND** no hash constant is hardcoded in the proxy source
- **AND** an opencode version bump that changes the inline script content
  is handled transparently on the next request

#### Scenario: 'unsafe-inline' is not introduced
- **WHEN** auditing the patched CSP header the proxy emits
- **THEN** `script-src` does NOT contain `'unsafe-inline'`
- **AND** `script-src` contains `'self'` and `'wasm-unsafe-eval'` plus one
  or more `'sha256-…'` entries
