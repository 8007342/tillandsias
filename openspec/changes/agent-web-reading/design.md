## Context

`curated-egress-tiers` gives each container a tier, and designs
`enclave-fetch` as the service agents read the web through. It names a
`research` tier and a catalog, but not what goes in it or how it is cached.

The operator's direction on 2026-11-26 is to widen agents' reading and keep
every existing exit open. This change fills the catalog with text-friendly
sources and caches them by kind.

## Decisions

### D1. One catalog, from which the allowlist is generated

`images/proxy/reading-catalog.yaml` has one entry per source:

```yaml
- url: https://lobste.rs/rss
  kind: feed            # feed | llms-txt | text-docs | docset | api
  refresh: 10m
  licence: "n/a (link aggregator)"
  provenance: "research 2026-11-26, fetched; order 2388-mihv"
```

`build-proxy-allowlist.lua` derives the `reading` tier from it, the same way
the other tiers are generated today. A host has one place it enters, and that
entry says why.

### D2. Cache by kind

These squid `refresh_pattern` rules come before the catch-all:

| Kind | Example match | min | percent | max |
|---|---|---|---|---|
| immutable artifact | `static.crates.io`, `/-/.*\.tgz$`, `proxy.golang.org/.*/@v/.*\.(zip\|mod)$`, `files.pythonhosted.org` | 1 week | 100% | 1 year |
| RFC text | `rfc-editor.org/rfc/rfc[0-9]+\.txt$` | 1 week | 100% | 1 year |
| docs | catalog `text-docs` and `llms-txt` | 1 hour | 20% | 1 day |
| feed | catalog `feed` | 5 min | 0% | 15 min |

The existing release-asset rule and the no-cache rule for query strings stay
first. A litmus test pins the order, because squid uses the first matching
rule.

### D3. The llms.txt probe proposes; the operator decides

`tillandsias-plan script run scripts/lua/probe-llms-txt.lua <host>` asks for
`/llms.txt`, `/llms-full.txt` and one `.md` page variant. It answers
`propose:<host>:<kind>` with the bytes it got, or `no-text:<host>`. A proposal
becomes a catalog entry only through the approval path in
`curated-egress-tiers` §6. Nothing is auto-allowed.

### D4. The local mirror is a sibling service

`docs-mirror` runs on `siblings` and serves:

- DevDocs docsets;
- Python's plain-text archive;
- chosen Kiwix ZIM files, through `kiwix-serve`.

It uses one internal hostname, and agents reach it with no internet. It
refreshes on a schedule through the proxy. Each docset records its upstream
licence. A docset whose licence forbids redistribution is served only to this
host, and never shipped in an image or release.

### D5. The reader runs locally

`enclave-fetch`'s `fetch(url)` returns Markdown, using a readability-style
extraction plus an HTML-to-Markdown converter inside the container. It does
not render JavaScript in this change; a headless renderer is a later option.
It uses no third-party reader service.

### D6. Denied hosts become proposals

A weekly summary of the proxy's denied-host log ranks hosts by count. The top
entries are probed (D3) and offered to the operator as catalog additions.

## Risks

- **Feeds change or disappear.** The catalog entry is the place to fix them,
  and a weekly probe marks a dead feed.
- **Licences.** Mirroring copies third-party docs, so D4 records each licence
  and limits redistribution.
- **Disk.** ZIM files are large, so the operator picks them (proposal,
  decision 2).
