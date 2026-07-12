# Forge proxy egress blocks Antigravity release server

- Date: 2026-07-12
- Class: enhancement (proxy egress gap)
- Filed by: forge-big-pickle meta-orchestration cycle 2026-07-12T20:03Z
- Related: order 307 (antigravity-launch-crash)

## Problem

The forge Squid proxy's egress allowlist does not include
`*.us-central1.run.app` domains. The Antigravity CLI installer
(`antigravity.google/cli/install.sh`) downloads successfully, but the
inner binary fetch from `antigravity-cli-auto-updater-974169037036.us-central1.run.app`
fails with `Connection reset by peer`.

Since agy is installed EVERY_LAUNCH (not baked into the image), the
binary is never present and the Antigravity lane cannot launch.

## Evidence

```
$ curl -fsSL --max-time 30 https://antigravity.google/cli/install.sh | head -5
# (downloads OK — 7354 bytes)

$ curl -fsSL --max-time 10 https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/
curl: (56) Recv failure: Connection reset by peer
```

No `run.app` domains appear in any proxy configuration file under
`scripts/` or `images/`.

## Fix

Add to the Squid proxy egress allowlist:
- `*.us-central1.run.app` (or more narrowly: `antigravity-cli-auto-updater-974169037036.us-central1.run.app`)

This is operator action — the proxy config is outside the forge
container's write scope.

## Blocked by

Operator (proxy configuration change).

## Next action

The Tlatoani or operator adds the domain to the proxy egress rules
and restarts the proxy container. After that, the Antigravity lane
should install agy successfully on launch (still needs a Gemini
credential in the vault — orders 303/304).
