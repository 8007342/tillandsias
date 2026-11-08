## Why

Every runtime container that has a proxy gets the same 119-domain hand-kept
allowlist (`images/proxy/allowlist.txt`, on port 3128). Squid splices TLS for
those domains and resets everything else, so:

- **One access level for everyone.** The vault, the router, a web studio and a
  forge cannot be given different reach.
- **Agents can't read the web.** They see "connection reset" for any
  documentation or research site that is not listed (row 2037-4ptq).
- **Every new need is a manual list edit.**

The operator's direction (2026-11-08, via the coordinator):

- Each service gets its own curated level, from none, through siblings, the
  host and an assets tier, up to curated internet.
- Agents get web search and fetch through a curated service, the way other
  harnesses do, not by curl.
- The model scales without curating each new need by hand, while staying fail
  closed, keeping TLS intact and never letting credentials leave the enclave.

This change is generic: any project's containers declare a tier.

## What Changes

- A fixed **tier ladder**:
  - `none`, `siblings`, `host`;
  - `registries`, `assets`, `providers`, `model-hubs`, `vcs`;
  - plus a `research` capability that is served by a service, not by the proxy.
- Each image descriptor and each studio-registry entry **declares** its tiers.
  A missing declaration means `none`.
- The proxy enforces tiers **per source**: one listening port per tier set,
  SNI-decided, spliced, with the CONNECT target checked against the SNI.
- An enclave **fetch/search MCP service** gives agents documentation and web
  research. It holds:
  - a curated catalog (docs sites, RSS/Atom feeds, APIs);
  - the search key, kept in Vault;
  - per-client rate limits and an audit log;
  - private-IP refusal, robots.txt and size caps.

  Pages are fetched by the service, never by the agent's shell.
- **Scaling without hand curation:**
  - package traffic moves to registry mirrors;
  - URLs returned by a search become fetchable for that session;
  - an unknown name is denied and queued for the operator's one-click approval
    in the tray, which writes a provenance-carrying catalog entry.
- **Migration:** allowlist.txt is split into tier files along its existing
  sections. The union stays equal to the old list until every container has
  declared its tiers, and then port 3128's union is retired.

## Capabilities

### New Capabilities
- `curated-egress-tiers`: per-container outbound access tiers, their
  declaration and enforcement, and the curated fetch/search service.

## Impact

Affected:
- `images/proxy/` (squid.conf, the tier files);
- every `images/*` descriptor and `data/studios.json` (via
  `scripts/lua/build-studio-registry.lua`);
- the `tillandsias-headless` container launch: network, proxy URL and the
  `NO_PROXY` contract;
- a new image for the fetch service, and the tray's approval prompt.

It touches specs `proxy-container` ("Generous developer-focused domain
allowlist"), `enclave-network` and `squid-proxy-integration`.

Rows: 2041-i3nk, 2041-jb57, 2041-csm4, 2041-u7pm, 2041-9aiq, 2041-j6yt,
2041-8azp, 2041-54ce.

Sources: `cheatsheets/security/agent-web-access-patterns.md` and
`cheatsheets/security/per-workload-egress-tiers.md`.
