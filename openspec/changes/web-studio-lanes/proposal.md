## Why

Operator direction 2026-10-25: a user tells an agent "I want to author this
website interactively", and a visual web studio window opens on the live
site, with drag and drop, resize, rich authoring tools, and live saves into
the forge checkout. The agent co-edits beside the user. Publishing goes
through the host-side Cloudflare deploy tool (order 1853-qr4h). It deploys
only the deploy branch, and only when the user explicitly asks. Cloud builds
are metered, so nothing builds on push.

No single studio fits every site. GrapesJS suits free-form static HTML. Decap CMS suits markdown static-site generators. TinaCMS and Puck suit
React/Next. Onlook suits Next.js with Tailwind. So every studio is offered
as a choice. The choice needs a user-facing pattern that the studios share,
and that any other launch with options can reuse: "we have N options for
this:", with a one-line brief per option and one `[Recommended]` tag.

Today the only browser-window authoring lane is OpenCode Web
(`run_opencode_web_mode`). Its pieces are already the shape a studio needs:
- versioned images ensured on first use (`ensure_versioned_images` over `launch_images::LaunchSite`);
- a router route (`RouterRoute::new` + `upsert_router_route` + `caddy_reload_routes`);
- an OTP session (`tillandsias_otp::issue_session`, `send_issue_web_session`, `wait_for_authenticated_opencode_web`);
- a host browser window (`launch_opencode_web_browser`);
- an in-forge front proxy that keeps long-lived streams alive (`images/default/sse-keepalive-proxy.js`);
- the separate preview publisher (`publish_local_service` → `local_web_preview::publish`).

Building six studios on those pieces, rather than six bespoke paths, shows
what they need in common. This change names those shared needs so that one
Lua and MCP service layer serves every studio.

## Vision

Operator direction 2026-10-25: the user authors on a touchscreen with a
stylus and speaks to the agent ("make all the elements on the left the same
size"). The studio window and the agent share one live page, so the agent
acts on what the user is pointing at and the user sees each change land.
This uses the existing infrastructure: the dev Chromium framework browser,
the forge checkout, the MCP co-edit channel, and the existing voice and
input paths. No new device stack is in scope here.

## Operator rulings 2026-10-25

- Silex is dropped entirely, to avoid mixed-licensing questions now.
- Agent and studio changes are COMMITTED. Commits are cheap and disposable, so every save becomes a commit; there is no "last write wins with a notice".
- Each studio uses its own auto-save and repo best practice (hooks, init files, save adapters), researched per studio and wired automatically for the project and the running agent.
- Studio windows open in the dev Chromium framework browser, so the user and the agent co-edit live.
- A project's studio choice is committed to `.tillandsias/config.toml`.
- Puck runs as a separate editor app that imports the site's components.

## What Changes

- **New capability `launch-option-choice`**: whenever a launch has more than one viable option, the agent and the tray present "we have N options for this:", with one line per option. Exactly one option carries `[Recommended]`, chosen by a detector over the project. The choice is committed to the project's `.tillandsias/config.toml`, and the user can change it.
- **New capability `web-studio-lane`**:
  - **The studio lane contract.** Each lane declares its studio id, image, entry command, framework detector, and save adapter. It reuses the OpenCode Web route, OTP, and window plumbing, keyed `studio.<label>`.
  - **The shared services** every lane uses:
    - a project-scoped write-back service with a path allowlist;
    - a live-reload / SSE keepalive front;
    - the framework detector;
    - an agent co-edit channel over MCP;
    - per-studio image build on first use into the reusable cache layer.
  - **The per-studio lanes**: GrapesJS, Decap CMS, TinaCMS, Puck, and Onlook.
- **New capability `web-studio-publish`**: the studio's Publish control hands off to the 1853-qr4h deploy tool. It moves the deploy branch only after an explicit user confirmation that names the revision. A save or a push never triggers a cloud build.
- Out of scope: Silex (licensing, operator ruling 2026-10-25). Also Webstudio and Plasmic, which persist to their own database or cloud rather than to the checkout. See design.md.

## Impact

- `crates/tillandsias-headless`:
  - `launch_images::LaunchSite` gains a `Studio(id)` arm;
  - a `run_studio_mode` sibling of `run_opencode_web_mode`;
  - the router label `studio.<label>`.
- A new `images/studio-*` family, built on demand and never prebuilt in the release image set.
- `scripts/lua/`: a studio registry and detector. `forge-plan`/browser MCP gain studio tools: `studio_options`, `studio_open`, `studio_changes`, `studio_publish_request`.
- Depends on 1853-qr4h (deploy tool) for publish. It does not block the editing lanes.
- Plan packets: 1859-57mi, 1860-auhm, 1861-nmpp, 1862-wrx5, 1863-dmke, 1864-ay3x, 1865-dn5h, 1866-9696.
