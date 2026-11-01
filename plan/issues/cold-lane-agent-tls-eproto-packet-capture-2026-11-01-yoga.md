# 1941-tlsh packet capture: the upstream rejects the request (2026-11-01, yoga)

Second addendum to `plan/issues/cold-lane-agent-tls-eproto-hop-2026-11-01-yoga.md`
(packet `1941-tlsh`). It corrects the "Bun re-handshakes inside the tunnel" reading in
`plan/issues/cold-lane-agent-tls-eproto-debug-capture-2026-11-01-yoga.md`.

Method: `tcpdump -s 128` (headers plus the first payload bytes only, no bodies),
run in a throwaway `alpine:3.22` container sharing the `tillandsias-proxy`
network namespace and filtered to opencode.ai's ranges on 443. Nothing was
installed on the host. opencode 1.19.5 ran by hand in a maintenance forge on
v56.10.31.2 (DEBUG plus BUN_CONFIG_VERBOSE_FETCH), and failed 80 s in:
`02:48:47.774Z level=ERROR message="stream error" … EPROTO`.

## The bytes on the proxy's upstream leg (one connection, 172.65.90.20:443)

- `.701630` the client sends the next model request, 331,124 bytes. Its first record header is `17 03 03 40 11`, TLS application data on the EXISTING session. A re-handshake would start `16 03` (a ClientHello), so Bun did NOT re-handshake.
- `.773267`, 71 ms later, the server sends ONE 24-byte record, `17 03 03 00 13`. 19 encrypted bytes is exactly a TLS 1.3 alert (2 alert bytes, 1 inner content type, 16 tag bytes), and it is the only 24-byte server record in the whole capture.
- `.773618` the client sends FIN, and the server sends FIN at `.779`. opencode then reports the alert as `EPROTO: The TLS handshake failed`, which is misleading.

So the hop is the UPSTREAM: opencode.ai's edge receives the request and ends the session with a TLS alert. The proxy only reports the end of the tunnel, and the client only reports the alert.

## A lead, one sample: request size

The client's requests on that connection grew with each turn of the session:
1502, 3141, 150682, 151421, 197058, 240951, 286047, 288599, 321016, 324843 bytes
(all answered), then 331124 (rejected). A 320 KiB (327,680 B) request limit at
the edge would fall exactly between the last success and the failure. That
would also explain why the failure time varies (1 to 20 minutes, depending on
how fast the context grows) and why 1 of the cold lanes never failed. NOT yet
shown: one sample only.

## Next actions on 1941-tlsh

1. Test the size lead: repeat the capture for two more failures and check each rejected request is the first one over ~327,680 B and every answered one under it. If it holds, the fix belongs in the agent: compact or trim context before a request crosses the limit, and turn the alert into a clear "request too large" error rather than EPROTO. Report it upstream to opencode too.
2. Drop the no-keep-alive treatment: keep-alive is not the cause.
3. Keep the bounded, logged retry, but it will not help if the cause is size: retrying the same 331 KB body would fail the same way. Retry only once the request has been made smaller.
