## 1. Close the direct paths (no operator decision needed beyond D1's recommendation)

- [ ] 1.1 Forge OpenCode config: `"websearch": false`, and a `webfetch` deny,
      with `"permission": "allow"` kept for everything else.
- [ ] 1.2 The same for Claude Code (WebSearch and WebFetch) and Codex (web
      search) in their forge configs.
- [ ] 1.3 Remove `.exa.ai` and `.tavily.com` from the forge-reachable tiers,
      then regenerate allowlist.txt with build-proxy-allowlist.lua.
- [ ] 1.4 A Lua litmus test reads each forge agent config and refuses any web
      tool that is not denied. Show it red on today's config first.

## 2. Backend interface in enclave-fetch (after curated-egress-tiers step 4)

- [ ] 2.1 `backend.search(query, limit)`, and a fake backend for tests.
- [ ] 2.2 Search results feed the session fetch set; a test shows a URL not in
      the results is refused.
- [ ] 2.3 Vault policy: one read path for enclave-fetch, and a test shows a
      forge token is refused on it.
- [ ] 2.4 Refuse to start without a key (D5); a test covers it.

## 3. First real backend (needs the operator: choice, account, key, terms)

- [ ] 3.1 The operator picks the backend and accepts its terms. Record the terms
      URL and sha256 on the row.
- [ ] 3.2 Implement it. The proxy `research` port admits its search endpoint
      only. A litmus test pins denial of the extract, crawl and scrape paths.

## 4. Research SearXNG (read and record only)

- [ ] 4.1 Licence, container image provenance, the engines it calls by
      default, rate-limit and ban behaviour, and its JSON API.
      Write it to plan/issues.
- [ ] 4.2 If it holds up, propose it as the default backend in this change's
      design.
