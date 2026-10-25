## Context

The OpenCode Web lane (`run_opencode_web_mode`) launches as follows:
1. **Identity.** It resolves the project identity (`resolve_launch_project_identity`) and refuses a lane socket owned elsewhere.
2. **Images.** It ensures the versioned images for `LaunchSite::OpencodeWeb`. `ensure_versioned_images` calls `ensure_image_exists` per tag, which builds on first use into the cache.
3. **Stack.** It brings up proxy, git, inference, and forge, idempotently.
4. **Route.** It starts the router (`ensure_router_running`) and upserts `RouterRoute::new("opencode.<router_host_label>", forge:4096)`, then calls `caddy_reload_routes`.
5. **Window.** `launch_opencode_web_browser` then:
   - waits for the route (`wait_for_opencode_web_route`);
   - issues an OTP (`tillandsias_otp::issue_session`);
   - registers it with the router sidecar over the tray control socket (`send_issue_web_session`);
   - waits for an authenticated 2xx (`wait_for_authenticated_opencode_web`);
   - opens an isolated Chromium window on a login data URL (`build_login_data_url`, `build_opencode_web_browser_spec`).

Inside the forge, `entrypoint-forge-opencode-web.sh` serves opencode on loopback :4097. `sse-keepalive-proxy.js` owns :4096. It injects SSE comments so Bun's idle timeout never drops `/event`, and it 404s PWA paths, which the ephemeral contract requires.

Previews of the user's own site are a different path: `publish_local_service` resolves the unique live instance and calls `local_web_preview::publish`. A studio needs both an editor surface and the live site, so it uses both paths.

## Studio survey (2026-10-25)

Star counts and release dates came mostly from model memory. Packet 1861-nmpp re-verifies them.

| Studio | License | Sites it edits | Writes back via | Runs as | Container fit |
|---|---|---|---|---|---|
| GrapesJS | BSD-3 | static HTML/CSS (React/Vue wrappers exist) | storage manager `remote` type: load/store HTTP endpoints we provide | JS library in a static page we host | good: tiny, no account; needs our save endpoint |
| Silex | AGPL-3.0 | static HTML (built on GrapesJS) | pluggable storage/hosting connectors; FS connector | Node/Express, one port | good; AGPL is fine unmodified, internal only |
| Decap CMS | MIT | markdown SSGs (Hugo, Jekyll, Astro, 11ty) | `local_backend: true` + `decap-server` proxy to the filesystem | static `/admin` page + node proxy (:8081) | very good; proxy has no auth, so it binds loopback behind the OTP router |
| TinaCMS | Apache-2.0 | Next.js first, also Astro/Hugo; md/mdx/json | `tinacms dev` local GraphQL (:4001) writes files | node dev server | ok; local mode needs no Tina Cloud |
| Puck | MIT | React (Next, Remix) | `onPublish` JSON; we persist it via a route | library inside the site's React app | good for React sites; edits component JSON, not arbitrary HTML |
| Onlook | Apache-2.0 | Next.js + Tailwind | edits code in the repo directly | Bun/Node app; web edition leans on hosted sandboxes/Supabase | questionable until offline viability is proven (1865-dn5h) |
| Webstudio | AGPL-3.0 | own Remix output | its own Postgres | node + Postgres | excluded: no write-back to checkout |
| Plasmic | MIT | React codegen | Plasmic server + `plasmic sync` | hosted studio | excluded: needs the vendor backend |

Default recommendation per detected framework:
- plain HTML: GrapesJS;
- markdown SSG: Decap CMS;
- Next.js with Tailwind: Onlook once 1865 passes, else TinaCMS;
- other React: Puck.

## Shared needs

These came out of building the lanes side by side. Each one becomes one service rather than one per studio.

1. **Option choice.** Detect the framework, then rank and recommend (the `launch-option-choice` capability).
2. **Image on first use.** Each studio is a `LaunchSite::Studio(id)` with its own image stacked on the forge base. It is built only when chosen and cached like any versioned image. It never joins the default prebuilt set.
3. **Route + OTP + window.** Reuse `RouterRoute`, `tillandsias_otp`, and the browser spec builder under the label `studio.<label>`. One session cookie covers both the editor and the live-site iframe origin.
4. **Write-back service.** A project-scoped HTTP save endpoint (GrapesJS remote storage, Puck `onPublish`, Silex FS connector). Decap and Tina bring their own writers, but every write still goes through the same path guard:
   - the canonicalized target must sit under the checkout;
   - it must not touch `.git/`;
   - it must match the lane's allowlist globs.

   Each write emits one `studio.save` event.
5. **Long-lived stream front.** Generalize `sse-keepalive-proxy.js` into a studio front:
   - SSE keepalive plus WebSocket passthrough for HMR;
   - the PWA kill paths;
   - a configurable upstream.
6. **Live site.** The preview behind the editor comes from `local_web_preview` (the same publisher as `publish_local_service`), not from a second server.
7. **Agent co-edit.** MCP tools `studio_options`, `studio_open`, `studio_changes` (a feed of saved paths plus diffs), and `studio_publish_request`. The agent edits files and the studio reloads them through the front's file watch. User saves arrive in the agent's feed.
8. **Publish handoff.** A single Publish control, described in the `web-studio-publish` capability.

The Lua side owns the registry: studio id, brief, detector, image, entry command, allowlist, and save adapter. The detector and the choice prompt read it, and the Rust lane only consumes it. That keeps the shell-to-lua direction.

## Decisions

- The studio runs inside the forge's network posture, not as a separate app network. It must write to the checkout, and the forge already owns the checkout.
- No studio receives credentials. Publish is a request to the host tool and never runs wrangler in the forge.
- A save writes files only. A commit stays an agent or user action, so the user can review diffs before publishing.

## Open questions

- Is Silex's AGPL acceptable when we ship it unmodified in an on-demand image? (A legal note is needed.)
- Can Onlook's web edition run with no Supabase or hosted sandbox? 1865-dn5h answers this. If it cannot, Onlook stays listed but marked "needs cloud account" and is never recommended.
- Should a Puck lane inject an editor route into the user's React app, or host a sidecar app that imports the user's component config?
- Concurrent edits: the agent and the user save the same file. Last-write-wins plus a conflict event, or a merge?
- Does a studio choice persist in the project (committed) or in host state only?
