## 1. Catalog and generated tier

- [ ] 1.1 `images/proxy/reading-catalog.yaml`, with the first entries from the
      proposal (feeds and text docs). Ars Technica and Phoronix go in only
      after a fetch verifies their feed URL.
- [ ] 1.2 `build-proxy-allowlist.lua` generates a `reading` tier from the
      catalog. A litmus test pins that the union of all tiers still contains
      every line the old allowlist had, so nothing is removed.

## 2. Cache by kind

- [ ] 2.1 Add the squid `refresh_pattern` rules from design D2, ahead of the
      catch-all.
- [ ] 2.2 A litmus test pins the rule order and checks that one sample URL of
      each kind matches the intended rule.

## 3. llms.txt probe

- [ ] 3.1 `scripts/lua/probe-llms-txt.lua`, with a fixture that runs it against
      a loopback fake host for all three outcomes.
- [ ] 3.2 Run it across the allowlist's docs hosts, and record the proposals on
      a row for the operator.

## 4. Local docs mirror (needs the operator's choice of docsets and disk)

- [ ] 4.1 A `docs-mirror` sibling service with kiwix-serve and a static server
      for DevDocs and Python text docs.
- [ ] 4.2 Record each docset's licence, and restrict redistribution where the
      licence requires it.

## 5. Local reader in enclave-fetch

- [ ] 5.1 HTML-to-Markdown in `fetch(url)`, with tests on three saved pages.

## 6. Denied-host review

- [ ] 6.1 A weekly summary of denied hosts, feeding task 3's probe.
