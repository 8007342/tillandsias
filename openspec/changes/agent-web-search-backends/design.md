## Context

`curated-egress-tiers` §5 designs `enclave-fetch`: an MCP service in its own
container offering `search`, `fetch`, `feed` and `docs`, so that agents read
the web through a curated service instead of the proxy. It says the search key
"is read from Vault and never enters a forge", but it does not choose a
provider. This change chooses one, and closes the direct paths that exist
today.

## Findings (2026-11-26, row 2388-mihv)

| Provider | Kind | OpenCode endpoint | Self-host | Keyless | Notes |
|---|---|---|---|---|---|
| Exa | hosted search | `mcp.exa.ai` | no | yes | OpenCode puts the key in the URL query, so logs carry it |
| Firecrawl | hosted scrape/crawl/search | `mcp.firecrawl.dev` | AGPL-3.0, but search still uses the cloud | documented | self-host API is unauthenticated and has no SSRF guard |
| Parallel | hosted search, extract, task | `search.parallel.ai` | enterprise only | unverified | standard terms allow training on inputs; zero retention is enterprise only |
| Tavily | hosted search, extract, crawl | `api.tavily.com` | no | search and extract only | no retention terms found |
| TinyFish | hosted agent, search, fetch, browser | `agent.tinyfish.ai` | no | conflicting | no retention terms found |

All five are SaaS. OpenCode calls only each provider's search tool, chosen by
`websearch.provider`, and `"websearch": false` removes the tool. Every vendor's
fetch, extract or scrape tool is an open proxy to the web.

## Decisions

### D1. Close the forge's direct web paths first

The forge's OpenCode config sets `"websearch": false` and denies `webfetch`,
so `"permission": "allow"` no longer reaches the web. `.exa.ai` and
`.tavily.com` leave every tier a forge uses. The other agents get the same
treatment: Claude Code's WebSearch and WebFetch, and Codex's web tool.

Until `enclave-fetch` ships, agents have no web search. That is a deliberate
step back from today's unapproved keyless path, and it is in line with the
operator's no-plaintext-credentials and agents-never-accept-terms rules.

### D2. One backend interface in enclave-fetch

```
backend.search(query, limit) -> [{title, url, snippet}]
```

A backend gets a query and returns results; it fetches nothing. Each search
result URL is admitted into the session's bounded, expiring fetch set (§5's
existing rule). `fetch` stays our code, with SSRF, robots, no-cookie and
rate-limit safeguards.

### D3. Only the backend's search endpoint is reachable

The proxy's `research` port admits exactly the chosen backend's search
hostname, from the `enclave-fetch` container only. A backend whose search and
fetch share one hostname (Exa's MCP, Tavily's API) needs a path rule as well
as a host rule. A deny on `/extract`, `/crawl` and `/scrape` is pinned by a
litmus test.

### D4. The key lives in Vault, and is read by enclave-fetch alone

The Vault policy grants `enclave-fetch` read access to one path. No forge
policy names that path. This is the same shape as the forge-cannot-read-the-
GitHub-token test (#1558).

### D5. No keyless use

A backend refuses to start without a key. Keyless means "you have accepted no
terms" (Tavily's own words), and agents may not use a service on terms nobody
accepted.

### D6. SearXNG as the self-hosted option

SearXNG is an open-source metasearch engine run in our own container. It
spreads queries across engines rather than one vendor, and needs no account.
It is not researched yet (task 4): licence, the engines it calls, rate-limit
behaviour and its container image. If it holds up, it is the preferred
default, because it needs no key, no terms and no single vendor.

## Risks

- **Search quality.** SearXNG's results may be worse than a paid API's.
  Mitigation: allow more than one backend, chosen per project.
- **Agent harnesses re-enabling their own tools.** An update could turn the
  built-in web tools back on. Mitigation: a litmus test reads each forge config
  and refuses `websearch` or `webfetch` that is not denied.
- **Vendor terms change.** Mitigation: the backend row records the terms the
  operator accepted, with a hash, the way `accept-licence` pins a licence text.
