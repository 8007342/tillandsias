# Cold-lane agent dies on EPROTO: which hop (2026-11-01, yoga)

Follows `smoke-finding/cold-lane-agent-dies-on-tls-handshake-without-blocked-marker`
(plan/issues/smoke-e2e-findings-v56.10.31.1-2026-10-31-linux-yoga.md, recurrence
in …-v56.10.31.2-2026-11-01-linux-yoga.md). Release v56.10.31.2, installed binary.

### Work Packet: 1941-tlsh

- id: `1941-tlsh`
- owner_host: linux
- capability_tags: [forge, opencode, proxy, testing]
- status: ready
- discovered_by: coordinator-directed investigation on yoga, 2026-11-01
- evidence:
  - Rate: 4 of 5 cold `--opencode` lanes on v56.10.31.x died with `Error: EPROTO: The TLS handshake failed. Does the server speak TLS on this port?` after 1 to 20 minutes (01:32Z run at ~4 min, 01:44Z run at ~70 s). The 01:39Z run did not fail: it ended `lane_exit=0` with `MO-FULL: BLOCKED`. Not a fixed lifetime, so not a cert or session expiry.
  - NOT the no_proxy / inference branch: the forge's `/home/forge/.config-overlay/opencode/config.json` has the agent model `opencode/big-pickle` (remote) and every local provider as `http://` (`127.0.0.1:11436`, `inference:11434`). From inside the forge, `curl https://inference:11434` gives `wrong version number` and `http://` answers `{"version":"0.34.0"}`. Nothing in the config dials inference as https.
  - NOT a direct dial: `ss -tnp` inside the forge, sampled every second for the whole failing run, shows every `opencode` socket peered with `10.0.42.4:3128` (squid), and no other peer.
  - NOT a squid refusal: squid splices (not bumps) every opencode host (`ssl_bump peek step1; bump release-assets.githubusercontent.com only; splice all`, the `ssl_bump` lines of `images/proxy/squid.conf`). In the failure window every opencode connection is a normal `NONE_NONE/200` (peek) followed by `TCP_TUNNEL/200` with data (opencode.ai 120860 B and 10210 B, models.opencode.ai 427457 B, HIER_DIRECT). No error, deny or non-CONNECT entry from the forge's address in any of the three captured runs.
  - opencode's own log (`~/.local/share/opencode/log/`) ends on a model stream start (`providerID=opencode modelID=big-pickle`, then "llm runtime selected") and never records the error; it is only on the lane's stdout.
- conclusion: the handshake fails INSIDE an established, spliced CONNECT tunnel, on the client side of it — the agent's TLS client (opencode on Bun) talking to opencode.ai through squid. Either a client-side tunnel reuse/pooling fault (the error text is Bun's, and it says the far end did not speak TLS), or the upstream answering non-TLS mid-session. Squid and the enclave network are not the hop.
- repro:
  - after a `podman system reset --force` + `tillandsias --debug --init`: `TILLANDSIAS_NO_TRAY=1 tillandsias --cloud 8007342/tillandsias --opencode --prompt "Use the /meta-orchestration skill"`; fails in most runs within 20 minutes.
- next_action: >
    Run the lane with opencode's debug logging and Bun's fetch tracing on
    (`--log-level DEBUG`, `BUN_CONFIG_VERBOSE_FETCH=curl`) to see which request
    failed and whether it reused a pooled proxy connection. If it is pooling,
    try disabling keep-alive to the proxy for the agent or pin a Bun/opencode
    release that fixes it; either way make the agent retry the stream instead
    of exiting, so a cold lane still ends with its MO-FULL: BLOCKED disposition.
- events:
  - type: discovered
    ts: `2026-11-01T01:46:00Z`
    agent_id: `linux-yoga-claude-20261027t070947z`
    host: linux
