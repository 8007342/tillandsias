---
tags: [web-fetch, web-search, mcp, agent-sandbox, egress, prompt-injection]
languages: []
since: 2026-11-07
last_verified: 2026-11-07
sources:
  - https://code.claude.com/docs/en/sandboxing
  - https://code.claude.com/docs/en/tools-reference
  - https://code.claude.com/docs/en/permissions
  - https://learn.chatgpt.com/docs/agent-approvals-security
  - https://learn.chatgpt.com/docs/web-search
  - https://opencode.ai/docs/permissions/
  - https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent
  - https://geminicli.com/docs/tools/web-fetch/
  - https://raw.githubusercontent.com/modelcontextprotocol/servers/main/src/fetch/README.md
  - https://github.com/brave/brave-search-mcp-server
  - https://github.com/upstash/context7
authority: high
status: current
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
pull_recipe: see-section-pull-on-demand
---

# How agent harnesses give web search and fetch without open egress

**Use when:** deciding how agents in a sandbox or container get documentation
and web research, or why "let the shell curl anything" is not the pattern.

## The shared pattern

The agent's **shell** gets no network, or a proxy with an allowlist. **Web
search and fetch are separate tools** that run outside the sandbox, under
their own permission rules, and return processed text, not raw sockets.

| Harness | Shell egress | Fetch / search |
|---|---|---|
| Claude Code | sandbox: separate netns (Linux) / Seatbelt (macOS); only a host proxy checking `allowedDomains` (starts empty); UDP/HTTP3 blocked | WebFetch: HTML→Markdown, then a separate model call answers over it; refuses localhost and dotless hosts; 100k chars, 15 min cache. WebSearch: provider backend, returns titles+URLs. `allowedDomains` does **not** limit WebFetch. |
| Codex CLI | network **off** by default; optional `network_proxy` domain list (deny wins), covers sandboxed commands only | hosted `web_search`: `cached` (default, provider index), `live`, `disabled`; `allowed_domains`; "treat all web results as untrusted input" |
| OpenCode | no documented OS sandbox (unverified) | `webfetch`/`websearch` permission actions, wildcard, last match wins; default allow |
| Pi (pi-mono) | none documented | no built-in web tool; extensions/MCP instead |
| Gemini CLI | — | `web_fetch` via the API's urlContext; fallback local fetch validates resolved IPs against private ranges and pins the connection |

## The MCP building blocks

- **Reference `fetch` server**: obeys robots.txt for model-initiated fetches
  (and refuses if robots.txt errors), identifying user-agent, `max_length`
  5000 default with paging, Readability-based HTML→Markdown, `--proxy-url`,
  refuses private/loopback/metadata IPs by default, `--allowed-hosts`. Not
  DNS-rebinding safe.
- **Brave Search MCP**: API key (file-loadable), selectable tools; its HTTP
  mode binds 127.0.0.1 with no auth.
- **Context7**: a docs index behind `resolve-library-id` / `query-docs`.

## Lessons

1. Put the credentialed parts (search API keys) in the service, never in the
   agent's environment.
2. Process content before the agent sees it (Markdown conversion, length caps,
   a summarising pass, or a cached index): this lowers prompt-injection risk
   but never removes it.
3. Allowing fetch does not stop curl: the shell's egress must be closed
   separately (Claude Code's own docs say so).
4. None of the harnesses document rate limits or audit logs for fetch; a
   self-hosted service has to add them.

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: several upstream doc sites; the summary above carries the claims used here.
> See `cheatsheets/license-allowlist.toml` for per-domain authority.

### Source

- **Upstream URL(s):**
  - `https://code.claude.com/docs/en/sandboxing`
  - `https://raw.githubusercontent.com/modelcontextprotocol/servers/main/src/fetch/README.md`
- **Archive type:** `single-html`
- **Expected size:** `~2 MB`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/agent-web-access-docs/`
- **License:** vendor documentation licences (see each site)
- **License URL:** see each upstream URL

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET_DIR="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/agent-web-access-docs"
mkdir -p "$TARGET_DIR"
curl --fail --silent --show-error -L "https://code.claude.com/docs/en/sandboxing" -o "$TARGET_DIR/0.html"
curl --fail --silent --show-error -L "https://raw.githubusercontent.com/modelcontextprotocol/servers/main/src/fetch/README.md" -o "$TARGET_DIR/1.html"
```

### Generation guidelines (after pull)

1. Read the pulled files for the exact option names and defaults cited above.
2. If your project needs a project-specific version, generate it at `<project>/.tillandsias/cheatsheets/security/agent-web-access-patterns.md` using `cheatsheets/TEMPLATE.md`.
3. The generated cheatsheet MUST set frontmatter: `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`, `committed_for_project: true`.
4. Cite the pulled sources under `## Provenance` with `local: <cache target above>`.

## Provenance

Retrieved 2026-11-07 by a research agent at the operator's request (via the
coordinator: "Other harnesses ... don't let agents curl the internet ... they
get web search and fetch through MCP services"). All `sources` are vendor docs
or the projects' own READMEs, read on that date, except for two points that are
inferred: that the OpenCode shell has no sandbox, and where Claude Code's fetch
executes. Cursor and Aider were not researched.
