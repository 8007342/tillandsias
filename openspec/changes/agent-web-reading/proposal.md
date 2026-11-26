## Why

The operator asked (2026-11-26) whether there are better ways to curate agents'
internet access than plain allowlists, with this direction: "We want to make
things easier for our agents, not harder", and "Do not close their search
exits."

Two research passes on the same day (sources cited in
`plan/issues/agent-web-search-providers-2026-11-26.md`) found:

- **OpenCode's five search providers are hosted SaaS search APIs.** These are
  exa, firecrawl, parallel, tavily and tinyfish; none is a container or a safe
  list.
- **They stay as they are.** The forge already reaches Exa and Tavily, and this
  change keeps that.
- **Much of the useful web serves text that caches well.**
  - **Feeds:** RSS and Atom from tech news.
  - **llms.txt:** a Markdown index that a growing number of docs sites publish.
  - **Plain text:** RFCs, and Python's text docs.
  - **Downloadable docsets:** DevDocs, and Kiwix ZIM files.
  - **Registry JSON APIs:** artifacts there are immutable, so they cache well.
- **Most of these hosts are not on the allowlist today.** That covers the
  feeds, `rfc-editor.org`, `docs.python.org` and `peps.python.org`. The
  allowlist already has `devdocs.io`, `docs.rs`, `pypi.org`, `.crates.io`,
  `.npmjs.org`, `.golang.org`, `.go.dev`, `.firebaseio.com`, `.github.com` and
  `.githubusercontent.com`.
- **squid caches everything the same way.** One `refresh_pattern . 0 20% 4320`
  covers all traffic. An immutable crate file and a feed that changes every
  10 minutes get the same treatment.

## What Changes

Agents can read more of the web, faster, with no current access removed:

1. **A `reading` catalog**, a versioned file of text-friendly sources. Each
   entry carries `url`, `kind` (feed, llms-txt, text-docs, docset, api),
   `refresh`, `licence` and `provenance`. The proxy allowlist for these sources
   is generated from it, so a host enters one place with its reason.
2. **First catalog entries:**
   - **Feeds:** lobste.rs, hnrss.org (Hacker News as RSS), the HN Firebase API,
     LWN, and The Register (www. and api.).
   - **Text docs:** www.rfc-editor.org, docs.python.org, peps.python.org.
   - **After verification:** Ars Technica and Phoronix.
3. **Cache rules by kind**, in squid, ordered before the catch-all:
   - immutable registry artifacts and RFCs: long-lived;
   - docs: hours;
   - feeds: 5 to 15 minutes;
   - the existing release-asset rule: unchanged.
4. **An llms.txt probe.** A tool asks a candidate docs host for `/llms.txt` and
   `.md` variants. Hosts that answer in Markdown are proposed for the catalog,
   with the probe's output as provenance. The operator still approves each
   addition, as `curated-egress-tiers` §6 already requires.
5. **A local docs mirror.** A sibling service serves DevDocs docsets, Python
   text docs and chosen ZIM files from one internal hostname. Agents can then
   read docs at LAN speed with no internet at all. Each docset's upstream
   licence is checked before it is mirrored.
6. **A local HTML-to-Markdown reader.** It joins `enclave-fetch`
   (curated-egress-tiers §5), so a page reached through search or the catalog
   comes back as Markdown. A third-party reader such as r.jina.ai would see
   every URL agents read, so this change does not use one.
7. **Denied-host review.** The proxy already logs denied hostnames. A weekly
   summary proposes the most-asked hosts for the catalog.

## Not changing

- OpenCode's search providers and their allowlist entries.
- The forge's `"permission": "allow"` and `webfetch`.
- Any existing allowlist line.

## Operator decisions this change needs

1. Approving the first catalog entries (item 2).
2. Which ZIM files and docsets to mirror, and the disk to give them (item 5).
   The full Wikipedia dump alone is very large.

## Impact

- `images/proxy/tiers/`: a generated `reading` tier.
- `images/proxy/squid.conf`: refresh rules by kind.
- A new catalog file, a probe tool, and a mirror sibling service.
- `enclave-fetch`: a Markdown reader.
- New capability spec: `agent-web-reading`.
