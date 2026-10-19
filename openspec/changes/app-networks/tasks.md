# Tasks — app-networks

Packet orders in brackets; dependency order top to bottom. Each task's
closure is the fixture or measurement named in its packet's exit criteria.
Research tasks close with a recorded measurement, build tasks with a fixture
written red against today's code first.

## 0. Measure (parallel; any host for its own substrate)

- [ ] 0.1 Rootful second-leg publishing matrix on the macOS and WSL guests [1800-b2gb]
- [ ] 0.2 IPv6-only app networks per substrate: aardvark AAAA, Caddy dial, Squid src ACL, gvproxy [1800-cp93]
- [ ] 0.3 Fleet ULA addressing plan and the Cloudflare ULA-route arm; decision note [1800-zk9i]

## 1. Lifecycle

- [ ] 1.1 `app_network.rs`: name, label, create, rm -f, reap-by-label at tray start; isolation live arm [1800-er9t]
- [ ] 1.2 Router second leg: connect on app start, disconnect on stop; S7 in `network-scenarios`; `enclave-network` connect rule; membership guard learns `tillandsias-app-` [1800-d29n]

## 2. Postures

- [ ] 2.1 Per-app Squid ACL include keyed on the app subnet; `none`/`allowlist`/`open` table; reconfigure on start/stop [1800-sdgk]
- [ ] 2.2 Posture in the launch API (`publish_local`, toolchain sessions), refusals, tray status line, agent-facing `service_status.network` [1800-seg8]

## 3. IPv6-first (gated on 0.2)

- [ ] 3.1 App subnets allocated from the host's ULA `/56`; IPv4 fallback only where 0.2 measured red [1800-pj2x]

## 4. Close

- [ ] 4.1 Live arms of the epic recorded on 1800-gjqq (Linux rootless, one guest)
- [ ] 4.2 Sync `app-networks` and the `network-scenarios` / `enclave-network` deltas into `openspec/specs/`

## 5. Fleet shared services (epic 1800-p47s; order is the dependency chain)

- [ ] 5.1 Host-side LAN discovery and trust: `_tillandsias._tcp` announce/browse in the tray, hint trusted only after the Cloudflare-login identity proof [1800-54yy]
- [ ] 5.2 Windows: the tray announces for the NAT-hidden WSL VM and forwards [1800-67gq, windows]
- [ ] 5.3 Shared inference: resolved `OLLAMA_HOST` and probe endpoint; router alias forwards to the LAN peer; proxy ACL for that one host [1800-8geu]
- [ ] 5.4 Shared nix cache on the LAN with distributed cert and public key as a substituter [1800-petu]
- [ ] 5.5 Build server: nix remote builder over the fleet sshd [1800-6pku]
- [ ] 5.6 Git mirror on the LAN behind authenticated push only [1800-swte]
