# Agent web-search providers: what OpenCode's five are (2026-11-26)

Order 2388-mihv. This was asked by the operator on 2026-11-26, and is the
input to the openspec change `agent-web-search-backends`.

Method: a research sub-agent read the OpenCode source (a shallow clone of
github.com/anomalyco/opencode, where sst/opencode now lives) and each vendor's
docs. It created no accounts, accepted no terms, used no keys, and sent no
request to any provider. Anything it could not confirm is marked unverified.

## What OpenCode does

- **Built-in plugins, not MCP config.** Each provider is a built-in plugin
  under `packages/core/src/plugin/websearch/`, and each hard-codes its endpoint.
- **Search only.** OpenCode calls only a provider's search tool. The query
  always leaves the machine.
- **Endpoints:**
  - `mcp.exa.ai/mcp`
  - `mcp.firecrawl.dev/v2/mcp`
  - `search.parallel.ai/mcp`
  - `api.tavily.com/search`
  - `agent.tinyfish.ai/mcp`
- **Keys:** read from `EXA_API_KEY`, `FIRECRAWL_API_KEY`, `PARALLEL_API_KEY`,
  `TAVILY_API_KEY` and `TINYFISH_API_KEY`. With no key, Exa, Tavily and TinyFish
  still send requests, keyless.
- **Selection:** `websearch.provider` picks the provider, and
  `"websearch": false` removes the tool. A `websearch.use` deny policy removes
  providers (OpenCode ≥ 2.2.6). Source: https://opencode.ai/v2/docs/websearch/
- **`webfetch` is separate.** It fetches any URL from the client, re-checking
  permissions on redirects. Behind our proxy it is the real open-web path.

## The five

| Provider | What it is | Self-host | Keyless | Data terms |
|---|---|---|---|---|
| Exa | hosted search index (https://exa.ai/docs/reference/exa-mcp) | no; the MCP server is a client only | yes; may 403 without a direct IPv4 path (unverified here) | zero retention is Enterprise (https://exa.ai/docs/reference/security) |
| Firecrawl | hosted scrape, crawl and search (https://github.com/firecrawl/firecrawl) | AGPL-3.0 Docker Compose, but search still reaches the cloud; no auth by default, and no SSRF guard documented (https://docs.firecrawl.dev/contributing/self-host) | documented "Try Instantly" (https://docs.firecrawl.dev/mcp-server) | not found |
| Parallel | hosted search, extract and task (https://docs.parallel.ai/search/search-quickstart) | enterprise on-prem only | unverified | may train on unlinked inputs under standard terms (https://docs.parallel.ai/resources/faqs) |
| Tavily | hosted search, extract, crawl and research (https://docs.tavily.com/documentation/api-reference/introduction) | no | search and extract (https://docs.tavily.com/documentation/keyless) | not found |
| TinyFish | hosted agent, search, fetch and browser (https://docs.tinyfish.ai) | none found | the OpenCode source says yes; the docs say login is required | not found |

## Findings that matter here

1. **None is a container or a safe list.** All five are SaaS. "Piggybacking"
   one only means allowing its hostname and holding its key.
2. **The forge already reaches two of them, keyless.**
   `images/default/config-overlay/opencode/config.json` sets
   `"permission": "allow"`, and `images/proxy/allowlist.txt` lists `.exa.ai` and
   `.tavily.com` (they are also in `.serper.dev`, `.brave.com`, `.perplexity.ai`
   and `.searchapi.io`). So a forge agent can search through Exa or Tavily today
   with no key, on terms nobody accepted.
3. **Every vendor fetch tool is an open proxy.** These are Exa web_fetch,
   Firecrawl scrape, Tavily extract, TinyFish fetch and browser, and Parallel
   Extract. None bounds what it retrieves. A search-only integration must deny
   their paths, not just allow a hostname.
4. **Exa's key is in the URL.** OpenCode passes it as a query parameter, so any
   proxy log of the URL carries the key.

## Recommendation

See `openspec/changes/agent-web-search-backends`:

- Close the forge's direct paths now.
- Serve search from `enclave-fetch`, with the key in Vault.
- First backend: Parallel or Tavily. Research SearXNG as the self-hosted default.
- Never use any vendor fetch tool, and never use keyless access.
