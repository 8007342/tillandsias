---
tags: [opencode, agent, cli, web-ui, serve, tui, session, coding-agent]
languages: []
since: 2026-04-25
last_verified: 2026-04-25
sources:
  - https://opencode.ai/docs
  - https://opencode.ai/docs/cli
authority: high
status: current
---

# OpenCode — CLI + web mode

@trace spec:agent-cheatsheets

## Provenance

- OpenCode official docs — overview (what opencode is, TUI vs web mode): <https://opencode.ai/docs>
- OpenCode CLI reference (`opencode`, `opencode serve`, `opencode web`, `--port`, `--hostname` flags): <https://opencode.ai/docs/cli>
- **Last updated:** 2026-04-25

**Version baseline**: opencode binary baked at `/opt/agents/opencode/bin/opencode` (linked into PATH as `opencode`). The forge ships `opencode serve` for the web UI.
**Use when**: launching OpenCode interactively or via Tillandsias' "Attach Here" web flow.

## Quick reference

| Command | Effect |
|---|---|
| `opencode` | start interactive session in CWD |
| `opencode serve` | run the HTTP server (port `4096`) for web UI clients |
| `opencode serve --port 4096 --hostname 0.0.0.0` | explicit bind for in-enclave access |
| `opencode --version` | bundled version |

| Path | Purpose |
|---|---|
| `~/.config/opencode/config.json` | global config — model providers, theme, agent overrides |
| `~/.config/opencode/tui.json` | TUI theme (default `tokyonight`) |
| `~/.local/share/opencode/storage/` | session DB (SQLite) — ephemeral in the forge unless preserved |
| `<project>/.opencode/` | project-scoped overrides if present |

| Tillandsias-specific path | Purpose |
|---|---|
| `http://<project>.opencode.localhost/` | router-fronted URL the tray opens for "Attach Here" / "Attach Another" |
| `127.0.0.1:<host_port>` (4096 inside container) | per-project loopback bind on the host |

## Common patterns

### Pattern 1 — Tillandsias web flow

The tray's "Attach Here" launches a browser window in app-mode pointed at `http://<project>.opencode.localhost/`. The router container reverse-proxies to the project's forge on the enclave. Multiple browser windows against the same forge are supported — that's what `Attach Another` does.

You don't run `opencode serve` manually in this flow; the entrypoint does it. Just open the browser window the tray gave you.

### Pattern 2 — model selection via config

```json
{
  "model": "anthropic/claude-opus-4-7",
  "providers": {
    "anthropic": {
      "options": {
        "apiKey": "..."
      }
    }
  }
}
```

In the credential-free forge, the API key isn't here — opencode reaches the user's auth state via the host (out of scope for this cheatsheet).

### Pattern 3 — multiple concurrent sessions on one forge

OpenCode Web supports multiple concurrent browser windows against the same `opencode serve` process. Sessions are independent; closing one doesn't affect others. The tray's "Attach Another" item just spawns a fresh browser window pointing at the same URL — no second container is started.

### Pattern 4 — terminal mode in the forge

```bash
opencode               # TUI mode in the current shell
```

Same agent, different surface. The TUI runs in the same forge container; if you started the forge via the tray's web flow, you can also `podman exec` in (or use the tray's "Maintenance" item) and launch the TUI in parallel.

## Common pitfalls

- **Trying to bind opencode serve to ports < 1024** — the forge user is not root; rootless. The convention is port `4096` (high port). The host-side router rewrites the public-facing URL to port 80 → 4096 enclave-internal.
- **Editing `~/.config/opencode/config.json` to set an API key in the forge** — the forge has no credentials by design. Attempting to embed an API key here is a `spec:forge-offline` violation. Auth flows through the host's tray, not in-forge config.
- **Closing a browser window expecting it to stop the forge** — closing windows is per-session. The forge keeps running until `Quit Tillandsias` triggers `shutdown_all`. (See `cheatsheets/runtime/forge-container.md` for lifecycle details.)
- **Mixing TUI and web modes in the same forge thinking they share session state** — they're separate `opencode` processes against the same container. Sessions are per-process; share via the project workspace, not via opencode itself.
- **Calling external Anthropic APIs from inside the forge** — the forge has no direct internet, only the proxy. If the proxy's allowlist doesn't include `api.anthropic.com`, the call fails. This is intentional in many configs.
- **Assuming OpenCode auto-loads CLAUDE.md** — OpenCode reads its own config + project AGENTS.md (if present), NOT Claude Code's CLAUDE.md. If you want both agents to share rules, mirror them in both files.
- **Trying to install agent extensions at runtime** — the forge image is the toolbox. Adding plugins/extensions means a forge image change (per `spec:default-image`), not a runtime install.

## Telemetry obligations — cheatsheet-telemetry

@trace spec:cheatsheets-license-tiered

Every cheatsheet consultation by opencode SHOULD emit one JSONL line to
`/var/log/tillandsias/external/cheatsheet-telemetry/lookups.jsonl` so the
host-side analytics (deferred to a follow-up change) can drive cheatsheet
refresh prioritization. Schema and example events are documented in
`runtime/external-logs.md` under "Producer: cheatsheet-telemetry".

The path is RW for forge containers (per `spec:cheatsheets-license-tiered`'s
relaxation of the original Reverse-breach refusal). Append-only — never
rewrite earlier lines. The tray auditor enforces a 10 MB rotate cap.

The most load-bearing event is `resolved_via: miss` — emit it whenever
you read a cheatsheet but had to pull deeper context (live-api,
pull-on-demand recipe, or web search). The miss log is what tells the
host which cheatsheets need refresh.

```bash
jq -cn --arg ts "$(date -u -Iseconds)" --arg cs "languages/python.md" \
       --arg q "asyncio cancellation" --arg via "miss" \
  '{ts: $ts, project: $TILLANDSIAS_PROJECT, cheatsheet: $cs, query: $q,
    resolved_via: $via, pulled_url: null, chars_consumed: 0,
    spec: "cheatsheets-license-tiered", accountability: true}' \
  >> /var/log/tillandsias/external/cheatsheet-telemetry/lookups.jsonl
```

## See also

- `agents/claude-code.md` — alternative agent, baked alongside opencode
- `agents/openspec.md` — change workflow opencode invokes via `/opsx:*` slash commands
- `runtime/networking.md` — why the credential-free / proxy-mediated network shape
- `runtime/external-logs.md` — full cheatsheet-telemetry schema + auditor invariants
- `runtime/cheatsheet-tier-system.md` — the tier system the telemetry events surface
