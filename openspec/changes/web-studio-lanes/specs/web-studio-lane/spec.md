## ADDED Requirements

### Requirement: each studio lane is a registry entry consumed by one generic launcher

Each studio SHALL be declared once in a Lua studio registry with these fields: `id`, `brief`, `detector`, `image`, `entry`, `port`, `save_adapter`, and `write_allowlist`. A generic `run_studio_mode` SHALL launch any registered studio by reusing the OpenCode Web lane plumbing: image ensure, router route, OTP session, and host window. No studio SHALL add a bespoke route, auth, or window path.

#### Scenario: launching a registered studio

- **WHEN** `run_studio_mode` launches studio `grapesjs`
- **THEN** the router holds a route `studio.<label>` and the window opens only after an authenticated 2xx
- **AND** an unauthenticated request to the route is refused
- **AND** the route is `studio.<router_host_label>` and the session came from `tillandsias_otp::issue_session` registered via `send_issue_web_session`

### Requirement: studio images are built on first use into the cache layer

A studio image SHALL be built only when that studio is first chosen, layered on the forge base, and tagged like every versioned image. Studio images SHALL NOT be part of any default prebuilt image set.

#### Scenario: first launch of a studio

- **WHEN** a studio is launched and its versioned tag is absent
- **THEN** it is built once, and a second launch builds nothing

### Requirement: every studio write passes one path guard

All saves SHALL pass one write-back guard, whether they come from the shared save endpoint or from the studio's own writer (decap-server, tinacms dev). The guard canonicalizes the target. It SHALL refuse any path outside the checkout, any path under `.git/`, and any path not matching the lane's `write_allowlist`. Each accepted write SHALL emit one `studio.save` event naming the path.

#### Scenario: a traversal save

- **WHEN** a save targets `../../etc/x` or `.git/config`
- **THEN** it is refused, nothing is written, and the refusal is evented

### Requirement: a shared front keeps streams alive and edits visible

Each studio SHALL be served behind a generalized front derived from `sse-keepalive-proxy.js`. The front SHALL:
- inject SSE keepalives;
- pass WebSocket upgrades through for hot reload;
- keep the PWA kill paths;
- serve the live site from `local_web_preview` rather than a second server.

#### Scenario: an idle studio

- **WHEN** a studio session sits idle past the upstream idle timeout
- **THEN** its event stream stays connected

### Requirement: the agent co-edits through MCP

The MCP surface SHALL expose these tools:
- `studio_options` (the choice list);
- `studio_open`;
- `studio_changes` (saved paths with diffs since a cursor);
- `studio_publish_request`.

When the agent writes a file, the open studio SHALL reload it. When the user saves, the save SHALL appear in `studio_changes`.

#### Scenario: user saves while the agent watches

- **WHEN** the user saves `index.html` in the studio
- **THEN** the next `studio_changes` call returns `index.html` with its diff

### Requirement: per-studio lanes

The registry SHALL contain these lanes:
- GrapesJS: static HTML, saved through the shared endpoint as the remote storage;
- Decap CMS: markdown SSGs, via `local_backend` and decap-server bound to loopback;
- TinaCMS: React/Next and markdown, via `tinacms dev` local mode;
- Puck: React, with `onChange`/`onPublish` routed to the shared endpoint;
- Onlook: Next.js with Tailwind, marked "needs cloud account" until proven offline.

#### Scenario: registry completeness

- **WHEN** `studio_options` is asked for any project
- **THEN** all five studios are listed with a brief each

### Requirement: Silex is not offered

The registry SHALL NOT contain a Silex lane (operator ruling 2026-10-25: no mixed-licensing questions now).

#### Scenario: options for a static HTML site

- **WHEN** `studio_options` is asked for a static HTML project
- **THEN** Silex is absent and GrapesJS carries `[Recommended]`

### Requirement: every studio and agent change is committed

Each accepted studio save and each agent edit through the co-edit channel SHALL be committed to the working branch, attributed to the user or the agent. Concurrent edits SHALL be ordered by commit; the system SHALL NOT resolve them by last-write-wins with a notice.

#### Scenario: user and agent edit the same file

- **WHEN** the user saves `index.html` in the studio and the agent then edits it
- **THEN** two commits exist in order, and `studio_changes` reports both SHAs

### Requirement: each studio uses its own auto-save and repo practice

Each lane SHALL wire its studio's native auto-save mechanism and repo conventions (init/config files, save adapters, hooks) automatically for the project and the running agent, as listed in design.md, scaffolding any missing config file without overwriting an existing one.

#### Scenario: first open of a Decap project

- **WHEN** the Decap lane opens a Hugo project without `admin/config.yml`
- **THEN** the lane scaffolds it, auto-save writes go through decap-server, and each save is committed

### Requirement: studio windows open in the dev Chromium framework browser

Studio windows SHALL open in the dev Chromium framework browser, so the user and the agent co-edit the same live page.

#### Scenario: opening a studio

- **WHEN** a studio is opened
- **THEN** the window is a dev Chromium framework browser window on `studio.<label>`

### Requirement: Puck runs as a separate editor app

The Puck lane SHALL run as a separate editor app that imports the site's component config, and SHALL NOT inject an editor route into the user's application.

#### Scenario: Puck on a Next.js site

- **WHEN** the Puck lane opens on a Next.js project
- **THEN** the user's app routes are unchanged and the editor app renders the site's components
