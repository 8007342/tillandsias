# Agent web access: the search providers, and text-friendly sources (2026-11-26)

Order 2388-mihv. This was asked by the operator on 2026-11-26, and is the
input to the openspec change `agent-web-reading`.

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

## Operator direction (2026-11-26)

"No I don't want to close those paths ... Do not close their search exits ...
We want to make things easier for our agents, not harder." The search
providers stay as they are.

## Second pass: text-friendly sources to add

A second research sub-agent ran on the same day, under the same rules.

**Feeds and open APIs.** The first four were fetched; the last two come from
listings only and are unverified:
- `lobste.rs/rss`;
- `hnrss.org`, Hacker News as RSS, Atom and JSON Feed, built on Algolia;
- the HN Firebase API at `hacker-news.firebaseio.com/v0`, which needs no key;
- The Register, on `www.theregister.com` and `api.theregister.com`;
- LWN at `lwn.net/headlines/rss`, from a search snippet;
- Ars Technica and Phoronix.

Reddit's `.rss` often refuses bots (unverified).

**llms.txt.** This is a Markdown index of a site's docs, proposed by Jeremy
Howard in 2024; the spec is at https://llmstxt.org/. Mintlify-hosted docs
generate one automatically. Each host still needs probing.

**Plain-text docs:**
- RFCs as text at `www.rfc-editor.org`; they are immutable;
- Python's plain-text docs archive at `docs.python.org/3/download.html`;
- PEPs.

**Mirrorable docsets:**
- DevDocs, under MPL, with each upstream licence kept;
- Kiwix ZIM files, including Stack Exchange and Wikipedia under CC-BY-SA.

Sizes were not retrieved.

**Registry JSON:** crates.io's sparse index, PyPI's JSON API, the npm registry
and proxy.golang.org. Versioned artifacts on all four are immutable, so they
cache well.

**Reader services.** r.jina.ai turns a page into Markdown, but it sees every
URL and allows 20 requests per minute per IP without a key. A local converter
avoids both.

**Curated agent allowlists.** No public, maintained one was found. GitHub
Copilot, GitLab Duo, Codex cloud and Docker Sandboxes each document their own,
but their contents were not retrieved.

**Already allowlisted:** devdocs.io, docs.rs, pypi.org, .crates.io,
.npmjs.org, .golang.org, .go.dev, .firebaseio.com, .github.com and
.githubusercontent.com.

**Not yet allowlisted:** the feeds, rfc-editor.org, docs.python.org and
peps.python.org.

## Recommendation

See `openspec/changes/agent-web-reading`:

- a catalog of text-friendly sources, from which a `reading` tier is generated;
- squid caching by kind;
- an llms.txt probe that proposes new hosts;
- a local docs mirror;
- a local Markdown reader in enclave-fetch;
- a weekly review of denied hosts.

Nothing existing is removed.
