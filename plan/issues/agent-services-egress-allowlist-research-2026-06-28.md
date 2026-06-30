# Research: Agent Egress Allowlist

## TCP_DENIED Harvesting
We extracted exact `TCP_DENIED` lines from `podman logs tillandsias-proxy`.
The exact denied FQDNs observed:
- `ab.chatgpt.com:443`
- `chatgpt.com:443`
- `platform.claude.com:443`

## Minimal Allowlist Delta
To support Codex/ChatGPT and Claude without encountering duplicate-subdomain FATAL errors in Squid, we will add their parent domains.

Delta for `images/proxy/allowlist.txt`:
```
.chatgpt.com
.claude.com
```
*(Note: `.anthropic.com` and `.openai.com` are already present).*

## Bump vs No-Bump Classification
- `.chatgpt.com`: no-bump (auth/telemetry endpoints often pin certificates or use WebSockets).
- `.claude.com`: no-bump (similar reasons, let it pass through transparently).

## Antigravity Agent-Wiring Gap
The Antigravity agent currently has no `entrypoint-forge-antigravity.sh`, so it cannot be launched to generate `TCP_DENIED` traffic. It is not fully wired as a Forge agent yet. This gap must be addressed in the subsequent implementation packet before its specific egress domains can be reliably harvested.
