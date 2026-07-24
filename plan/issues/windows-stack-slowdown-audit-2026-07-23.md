# Windows stack slowdown audit — 12 adversarially-verified findings (fat-agent fleet, live measurements)

- Date: 2026-07-23; host: windows (operator report: "codex launches very
  slowly" on a fast network + decent host)
- Method: 4 fat auditors with live read-only guest measurement + 1
  adversarial verifier per finding (23 agents; every number re-derived).
  Full measurements in the workflow transcript; key numbers below.
- Session context: measured against the OPERATOR'S REAL codex launch
  (03:36:49-03:42:38 UTC — 349s click-to-prompt).

## Where the 349s codex launch actually went

| Segment | Cost | Cause |
|---|---|---|
| Teardown + one-shot churn | ~14s | serialized podman one-shots (8 vault exec cycles, old-lane removes) |
| Login container | 50s BLOCKING | re-pulls 136MB @openai/codex npm + runs the FULL harness ensure before the device code shows |
| Clone + container start | ~7s | healthy (100MB pack in 2.7s) |
| **Codex TUI silent stall** | **281s (80%)** | **ephemeral CODEX_HOME: every launch replays codex FIRST-RUN (statsig experiments + model-availability NUX; 90s+120s ab.chatgpt.com tunnels moving <6KB)** |

Egress exonerated: proxy RTTs 96-160ms, all chatgpt.com requests <1.1s.
The network was never the problem — state amnesia was.

## The multipliers

- **Squid ssl_bump rule order makes bumping unreachable → 0% HTTPS cache
  hit rate, ever** (846/846 requests TCP_TUNNEL, 0 certs minted, cache dir
  empty). Every artifact always comes from origin.
- **~1.09GB re-downloaded per lane launch** (claude 273MB dist TWICE
  within 7s — ephemeral launcher symlink defeats the persistent versions/
  cache + self-update on the --version probe; 60MB cargo tools; 136MB
  codex npm in the login one-shot).
- Same 1.44GB ollama tarball tunneled 4x in 20 minutes (5.76GB) — bump
  bug + signed release-asset URLs not cached. GitHub release assets are
  replaceable unless a repository has separately enabled immutable releases,
  so this audit does not treat the CDN hostname itself as proof of immutability.

## Host-side (windows lane) — FIXED this commit

- **GetVaultHandover slept 8x1s on EVERY steady-state wire connection**
  (measured 8.1-8.2s per --status-once, x4 reproducible; the tray start
  paid it TWICE serially => ~17s warm tray-start->attach-clickable).
  Fixed: HANDOVER_DELIVERED flag — only the first request per headless
  process may poll; steady state answers instantly. Guest-side code,
  rides the next daily; hot-injectable if needed.
- Residual tray nicety (doc-only): Subscribe could carry an initial
  VmStatusPush to save the first poll roundtrip.
- Order-418 probe: attach clicks measured CHEAP (141-161ms warm) — the
  probe design is vindicated; but its 60s-timeout=>damaged=>destructive
  reimport rule can nuke a healthy distro during a transient WSL-service
  wedge. Refinement filed in the packet below (windows-260723-1).

## Packets filed (see plan/index.yaml)

- windows-260723-2 codex-lane-state-amnesia (CODEX_HOME persistence +
  login-container slimming) — the 281s + 50s
- windows-260723-3 harness-refresh-not-byte-cheap (short-circuit when
  current + kill the double claude download)
- windows-260723-4 proxy-cache-never-hits (ssl_bump order + artifact
  caching for the exact release-asset CDN while preserving origin semantics)
- windows-260723-1 exec-probe-timeout-not-damage (418 refinement)

## windows-260723-4 security-preserving static checkpoint

The source-level cause is confirmed against Squid 6's own rule semantics.
Squid evaluates every `ssl_bump` rule at every applicable bump step and uses
the first possible action. The old bare `ssl_bump peek all` therefore matched
again at `SslBump2` and normally made the later bump action unreachable.

The current static slice replaces that ambiguous pipeline with one explicit
trust boundary:

- `peek` is guarded by `at_step SslBump1`;
- only the exact client-requested SNI
  `release-assets.githubusercontent.com` may be bumped;
- `ssl_bump splice all` is the terminal fallback, so GitHub/API/raw-content,
  package-registry, provider/auth, and all other TLS-sensitive traffic retains
  end-to-end certificate and pinning decisions;
- Squid verifies the bumped origin against the system CA. Neither
  `DONT_VERIFY_PEER` nor `DONT_VERIFY_DOMAIN` is active;
- the bounded cache is 4096 MiB with a 2048 MiB per-object ceiling, so the
  observed ~1.44 GiB object is at least storage-eligible;
- the exact-host refresh rule is first but does not override `private`,
  `no-store`, reload, or explicit origin freshness;
- `strip_query_terms on` keeps signed query credentials out of access logs
  only. Query terms remain in the cache key. No StoreID or URL rewrite is
  present because a wrong mapping can serve different content under one key;
- the container entrypoint executes `squid -k parse` after runtime CA/cache
  initialization and before starting the foreground proxy.

Static evidence on this forge is green:

- `cargo test -p tillandsias-headless --test proxy_cache_policy`: 3/3;
- `./scripts/run-litmus-test.sh --spec proxy-container --size instant`: 2/2
  executed tests passed (the e2e test was excluded by the size filter);
- the proxy shape litmus pins the exact ACL/action order, origin verification,
  cache-control safeguards, size bounds, signed-query log privacy, and the
  pre-launch parser gate.

This is not yet evidence that repeated GitHub redirects hit the cache. This
forge has neither Podman nor Squid, and signed redirects may produce different
query-bearing cache keys. The packet therefore remains `in_progress`.

### Exact live closure action

On a mutable Linux host with Podman, check out the implementation commit from
`linux-next`, rebuild the proxy through the sanctioned
`tillandsias --init --debug` boundary, and retain the startup line proving
`squid -k parse` passed. From a forge/client container with the generated CA
installed:

1. Resolve one small public GitHub `browser_download_url` to its final
   `release-assets.githubusercontent.com` URL, keeping the signed query only in
   a process-local variable and out of the ledger.
2. Request that identical final URL twice through the strict proxy. Require
   equal response checksums plus `TCP_MISS` on the first request and
   `TCP_HIT` on the second.
3. Separately repeat the public redirect URL and record whether GitHub issued
   the same or a different final key. If the key changes, keep this packet open
   and file a fixture-backed StoreID decision; do not normalize it here.
4. Confirm access logs omit query terms and that representative non-target
   hosts (`github.com`, `api.github.com`, a package registry, and a provider
   endpoint) remain `TCP_TUNNEL`, not bumped.

Only those real-Squid observations can close the live cache-hit criterion.

### Primary references

- https://www.squid-cache.org/Doc/config/ssl_bump/
- https://wiki.squid-cache.org/Features/SslPeekAndSplice
- https://www.squid-cache.org/Doc/config/acl/
- https://www.squid-cache.org/Doc/config/refresh_pattern/
- https://www.squid-cache.org/Doc/config/strip_query_terms/
- https://www.squid-cache.org/Doc/config/store_id_program/
- https://docs.github.com/en/rest/releases/assets
- https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases
