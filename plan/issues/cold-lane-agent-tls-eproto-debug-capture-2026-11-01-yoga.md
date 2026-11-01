# 1941-tlsh debug capture: EPROTO is a request on a reused tunnel (2026-11-01, yoga)

Addendum to `plan/issues/cold-lane-agent-tls-eproto-hop-2026-11-01-yoga.md`
(packet `1941-tlsh`, id confirmed by the coordinator). Captured with opencode
1.19.5 run by hand in a `--cloud 8007342/tillandsias --bash` forge on the
installed v56.10.31.2, with `--print-logs --log-level DEBUG` and
`BUN_CONFIG_VERBOSE_FETCH=curl`, same prompt as the cold lane. Attempt 1 ran
7.5 min clean (rc 0); attempt 2 failed after 3 min 45 s.

## The failure, to the millisecond

- `02:37:03.573Z` opencode starts the next model stream (`providerID=opencode modelID=big-pickle`), 17 s after the previous stream's `200 OK` with `Connection: keep-alive`.
- `02:37:03.834Z` squid logs the end of the agent's opencode.ai tunnel: `TCP_TUNNEL/200 781728 opencode.ai:443 HIER_DIRECT`, open 224704 ms. Every model stream of the session rode this ONE pooled tunnel.
- `02:37:03.835Z` opencode: `level=ERROR message="stream error" … error.error="TypeError: EPROTO: The TLS handshake failed. Does the server speak TLS on this port?"`, then the process exits. The other two tunnels close at 03.910 (process exit).

## What this rules in and out

- Squid did NOT time the tunnel out first. The squid config sets no `read_timeout`, `client_idle_pconn_timeout` or `client_lifetime` (defaults 15 min / 2 min / 1 day), and the tunnel had been idle 17 s, not 2 min. It closed 261 ms AFTER the request started and 1 ms BEFORE the error, so the close follows the request.
- The error is a HANDSHAKE failure on a connection that had already carried 781 KB of TLS. The most likely reading is that the client began a new TLS handshake inside an existing CONNECT tunnel, i.e. Bun's fetch reused the pooled proxy socket as if it were a fresh tunnel; opencode.ai then saw a ClientHello in the middle of a TLS stream and dropped it, and squid logged the end. Not yet proven: see next action 1.
- The coordinator's half-open hypothesis (squid closed the upstream, then Bun wrote into a dead tunnel) does not fit the order: the tunnel was alive until the request.

## Next actions on 1941-tlsh

1. Prove the reuse: sample `ss -tnp` on the agent's sockets to 3128 just before and after the failing request (the same local port on both sides shows reuse). Then test the fix: fresh tunnels per stream (no keep-alive on the provider's fetch) or a Bun/opencode release that pools TLS sessions rather than raw proxy sockets. The failure rate (4 of 5 cold lanes, plus 1 of 2 hand runs) gives the bar.
2. Retry, per the coordinator: retry only the failed model request, a small fixed bound (for example 2), and log every retry, so the reuse fault stays visible and is not masked.
