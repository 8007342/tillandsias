# Impl: Agent Egress Allowlist

## Allowlist Delta
We added `.chatgpt.com` and `.claude.com` to `images/proxy/allowlist.txt`. These domains cover the missing auth and telemetry endpoints necessary for the Codex (ChatGPT) and Claude agents. We opted for the parent domains to avoid duplicate-subdomain FATAL errors in Squid.

## Bump/No-Bump Adjustments
In `images/proxy/squid.conf`, we added both `.chatgpt.com` and `.claude.com` to the `no_bump_domains` ACL. These endpoints use WebSockets and have certificate pinning which transparent SSL interception (bumping) would break.

## Antigravity Wiring
Added `images/default/entrypoint-forge-antigravity.sh` configured for the `agy` CLI binary. Wired it into `images/default/Containerfile`, allowing the Google Antigravity agent to launch successfully in the Forge runtime.

## Drift Protection
Added `litmus:agent-egress-allowlist-shape` (bound to `spec:proxy-container`) to ensure the `.chatgpt.com` and `.claude.com` entries are maintained in the allowlist and correctly classified as no-bump in the `squid.conf`. Litmus checks currently pass.
