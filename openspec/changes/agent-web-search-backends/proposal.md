## Why

When an agent in a forge needs the web, OpenCode asks to use one of five
search providers: exa, firecrawl, parallel, tavily and tinyfish. The operator
asked (2026-11-26) what these are, and whether they could give agents safe
internet access through our proxy.

Research, row 2388-mihv. Sources: the OpenCode source and each vendor's docs,
cited in `plan/issues/agent-web-search-providers-2026-11-26.md`.

- **What they are.** All five are hosted SaaS search APIs. None is a container
  image or a curated safe list.
  - Only Firecrawl has an open-source, self-hostable server (AGPL-3.0). Its
    search still goes to Firecrawl's cloud.
- **How OpenCode uses them.** Each is a built-in OpenCode plugin with a
  hard-coded endpoint, and OpenCode calls only the provider's search tool.
  - The query always leaves the machine.
  - The key is read from an env var: `EXA_API_KEY`, `TAVILY_API_KEY`, and so on.
- **They work today.** The forge's OpenCode config sets `"permission": "allow"`,
  and the proxy's allowlist already contains `.exa.ai` and `.tavily.com`. Exa,
  Tavily and TinyFish also have keyless paths. So a forge agent can search
  through Exa and Tavily today without any key, on terms nobody has accepted.
- **The open hole is webfetch.** OpenCode's `webfetch` tool fetches any URL from
  inside the forge. The search providers only return snippets.
- **Their fetch tools are open proxies.** Every vendor except OpenCode's
  search path offers a fetch or scrape tool that retrieves any URL on their
  side: Exa web_fetch, Firecrawl scrape, Tavily extract, TinyFish fetch and
  Parallel Extract.

So none of them can be "piggybacked" as a safe list. Two things are safe to
build:

1. Search as a service that holds the key outside the forge.
2. Fetch bounded by our own catalog.

`curated-egress-tiers` already designs that service, `enclave-fetch` (design
§5). This change chooses its search backend, and closes the paths that exist
today.

## What Changes

- **Close the forge's direct web paths now**, without waiting for
  `enclave-fetch`:
  - OpenCode's forge config sets `"websearch": false` and denies `webfetch`.
  - The `.exa.ai` and `.tavily.com` lines leave the forge-reachable tiers.
  - Claude Code and Codex get the same treatment for their built-in web tools.
- **`enclave-fetch` search gets a pluggable backend.**
  - Its `search(query)` tool calls exactly one configured provider.
  - The provider's key lives in Vault and is read only by the `enclave-fetch`
    container; it never reaches a forge.
  - Only that provider's search endpoint is reachable, on the proxy's
    `research` port, and never its fetch, extract, scrape or crawl endpoints.
- **Backends:**
  - **First choice: Parallel or Tavily.** Each is one hostname with a Bearer
    header.
  - **Self-hosted option: SearXNG**, in its own container, so queries go to
    no single vendor. It is not researched yet (row 2388-mihv task 4).
  - **Exa:** only if the key is held outside the agent and the endpoint is
    never logged, because OpenCode puts the key in the URL.
  - **TinyFish:** not used, because its data terms are undocumented and its
    keyless path conflicts with its own docs.
  - **Firecrawl:** self-hosting only gives scrape and crawl, which we do not
    want; search is not self-hostable.
- **Fetch stays ours.** `fetch(url)` keeps the catalog-plus-search-results rule
  from `curated-egress-tiers` §5, with its SSRF and robots safeguards. No vendor
  fetch tool is used.
- **Keyless use is refused.** A keyless request means an agent used a service
  under terms nobody accepted. Agents never accept terms. So a provider is
  usable only with an operator-created key and the operator's acceptance of its
  terms.

## Operator decisions this change needs

1. Which search backend: Parallel, Tavily, SearXNG, or more than one.
2. Creating the provider account and key, and accepting its terms. Only the
   operator does this, and the key goes into Vault.
3. Whether to close the current keyless Exa and Tavily path now. This change
   recommends yes.

## Impact

- `images/default/config-overlay/opencode/config.json`, and the Claude and
  Codex forge configs.
- `images/proxy/tiers/*.txt`, and the generated `allowlist.txt`.
- `enclave-fetch` (curated-egress-tiers §5): a backend interface, and one
  backend implementation per approved provider.
- New capability spec: `agent-web-search`.
