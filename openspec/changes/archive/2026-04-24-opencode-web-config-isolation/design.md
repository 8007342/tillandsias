# Design: opencode-web-config-isolation

## Context

Live diagnosis of a user's v0.1.160.198 session revealed the OpenCode Web UI
was presenting behaviour that violated the spec's privacy-first / per-project
isolation contract:

- `GET /config` showed `provider.ollama.options.baseURL =
  http://localhost:11434/v1`. Inside the forge container, `localhost:11434` is
  the forge container itself — there is no ollama there. The enclave's
  inference container is reachable at `http://inference:11434`.
- The full OpenCode provider matrix was visible: OpenCode Zen (external),
  OpenRouter (external), Helicone (external), plus the local ollama. A
  privacy-first local dev environment must not expose external providers.
- `GET /project` returned two entries: the mounted project and a "global"
  pseudo-project at `/`.
- The Tauri webview had no devtools. Diagnosing the SSE disconnect (separate
  issue, tracked elsewhere) was impossible without the inspector.

Root cause for items 1-3 was identical: the opinionated overlay config at
`images/default/config-overlay/opencode/config.json` was mounted into the
container at `/home/forge/.config-overlay/` but never linked into
`/home/forge/.config/opencode/`. The Containerfile baked a minimal stub
(`autoupdate: false`, nothing else) into `~/.config/opencode/config.json` and
that stub won.

## Decisions

### Decision 1 — Entrypoint copy vs symlink

We copy the overlay file into `~/.config/opencode/config.json` rather than
symlinking. Two reasons:

- OpenCode, on startup, writes `autoupdate` state (and sometimes pruning/cache
  state) to this file. A symlink would write back into the overlay mount,
  which is read-only on the container side and bound to the host cache.
- A copy matches the `tui.json` precedent already in the Containerfile
  (`COPY config-overlay/opencode/tui.json /home/forge/.config/opencode/`).

The overwrite happens on every container start — stale sessions are rebuilt
from the canonical overlay.

### Decision 2 — Fix to the OpenCode config schema (not a monkey-patch)

Our earlier overlay used `provider.ollama.api_url`, which OpenCode silently
ignored. The actual schema (from `https://opencode.ai/config.json`) is
`provider.<id>.options.baseURL`. We adopt the schema exactly — no alias, no
shim. Path suffix `/v1` matches OpenCode's OpenAI-compatibility layer (ollama
exposes `/v1/chat/completions`-style endpoints alongside its native API).

### Decision 3 — `enabled_providers: ["ollama"]` (allowlist, not denylist)

OpenCode auto-loads every provider it has bindings for. To enforce
privacy-first isolation we use the ALLOWLIST form (`enabled_providers`)
rather than adding every provider to `disabled_providers`. Two reasons:

- Future OpenCode releases may add new providers; allowlist form is
  default-deny.
- The spec text is clearer: "ollama only" is a positive statement, readable
  at a glance.

This removes OpenCode Zen (the default), OpenRouter, Helicone, Anthropic,
OpenAI, and every other matrix entry from the UI. The user sees exactly one
provider (ollama) with the models the inference container has pulled.

### Decision 4 — `default_agent: "build"`

The overlay already declares a `build` agent with open Bash/Read/etc.
permissions. Setting it as `default_agent` removes ambiguity on the first
session — a fresh forge always opens in the intended agent. If the user
wants a different agent they can select one per-session.

### Decision 5 — Unconditional webview devtools

The previous gate `#[cfg(debug_assertions)]` scoped devtools to local debug
builds. This means a user hitting a production build (AppImage install, CI
artifact) has no way to inspect the webview when something misbehaves.

Tillandsias's target audience is developers who already have an expectation
that webview dev tools are available in tools like Electron apps. The
security argument (devtools exposes window internals) is weak here: the
webview only loads local loopback content under the user's own session.
Enabling devtools unconditionally keeps the support surface small (one code
path) and matches user expectations.

### Decision 6 — "global" project stays (upstream OpenCode behaviour)

`GET /project` returning a "global" entry rooted at `/` is intrinsic to
OpenCode's data model — opencode creates this row on first database
initialisation. Removing it would require either patching OpenCode or
deleting rows from the opencode.db on every start (which also clears
session history and snapshots). Neither is in scope for this change.

We accept the duplicate entry and note it as a known upstream quirk in the
cheatsheet. If user feedback confirms it's a meaningful UX problem, a
follow-up change can add a pre-`opencode serve` SQL step to
`DELETE FROM project WHERE id='global'`, but we will not do that without
explicit user validation.

### Decision 7 — SSE disconnect after first prompt: diagnose, do not patch

Observed pattern: opencode's SSE event stream closes ~4 seconds after
`session.idle`. The client doesn't reconnect on next user action, so the UI
appears hung. This is either (a) an OpenCode UI bug, (b) a WebKitGTK issue
with long-held SSE under Tauri, or (c) an OpenCode server policy of closing
idle event streams.

Rather than speculate-and-patch, we enable webview devtools (Decision 5) so
the user can inspect Network + Console state when the hang reproduces. The
spec for this investigation is deferred to a future change; this change's
scope is config isolation.

## Alternatives Considered

- **Write a tiny Bun wrapper that intercepts HTTP requests and injects config.**
  Rejected: over-engineered; OpenCode already has config-file discovery.
- **Rebuild the forge image with the overlay baked in.** Rejected: the whole
  point of the overlay mount is to let the host update configs (per release,
  per GPU tier, per locale) without rebuilding the image. Keep the overlay
  mount as the canonical path.
- **Delete the "global" project on startup.** Rejected for this change —
  upstream OpenCode behaviour, needs user validation before we touch their
  DB. Tracked as a potential follow-up.

## Trace requirements

- `@trace spec:opencode-web-session, spec:layered-tools-overlay` on the
  new entrypoint overlay-copy block.
- `@trace spec:opencode-web-session` on the `enabled_providers` and
  `default_agent` keys (inline JSON comment not possible; reference in
  commit body + PR description).
- `@trace spec:opencode-web-session` on the unconditional `.devtools(true)`
  in `webview.rs`.

## Verification plan

1. Apply changes. `./build.sh --test` passes.
2. `./build.sh --release --install` produces a new AppImage and a rebuilt
   `tillandsias-forge:v<VERSION>`.
3. Launch the AppImage, attach any project in web mode.
4. Open the OpenCode Web window. Press F12 — inspector must open (Decision 5).
5. `curl http://127.0.0.1:<port>/config | jq '.provider.ollama.options.baseURL'`
   must return `"http://inference:11434/v1"`.
6. `curl http://127.0.0.1:<port>/config/providers | jq '.providers[].id'`
   must return exactly `"ollama"`.
7. UI loads in dark theme immediately (no flash of light).
