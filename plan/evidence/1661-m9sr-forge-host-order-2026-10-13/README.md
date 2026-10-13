# 1661-m9sr: forge guidance names dev URLs in the order the router routes

The operator's forge failed on yoga on 2026-10-13 (private project lakanoa).
The startup context told the agent to hand out
`http://${project_name}.<service>.localhost/`, but the router, the browser
allowlist and the sidecar route `<service>.<project>.localhost`
(spec subdomain-naming-flip). The agent followed the context and got
"no route".

## Guard

`allowlist::tests::forge_guidance_hosts_parse_with_the_router_rule` checks
two sources:
- the startup context's "Web servers" block (images/default/lib-common.sh);
- the agents' web-services instruction
  (images/default/config-overlay/opencode/instructions/web-services.md).

It extracts every example `….localhost` host from both and runs each through
the router's own rule, `allowlist::validate`:
- templates get a sample project and service (`${project_name}`, `<project>`
  and `$TILLANDSIAS_PROJECT` become demo; `<service>` becomes web);
- concrete examples are checked against the project names the doc itself uses.

`OpencodeSelf` (the browser's own no-self-reference policy) is not a shape
failure.

- `red.txt`: on linux-next, 8 hosts fail. The context's
  `${project_name}.<service>.localhost`, plus 7 in web-services.md: the
  template, `lakanoa.flutter`, `java.opencode`, `thinking-service.vite`,
  `my-api.next`, and two `$TILLANDSIAS_PROJECT.flutter`.
- `green.txt`: after the fix, it passes.
- `mutation.txt`: restoring only the context's old order fails the guard with
  "project suffix mismatch: expected demo, got web".

## Fix

The order is flipped in the context, in web-services.md (template, 4 examples,
2 `$TILLANDSIAS_PROJECT` URLs) and in images/proxy/squid.conf's comment.

## Left for others

- **Whether forge dev servers are routed at all:** that is 1662-udb3 (the
  context will say only publish_local is routed).
- **Stale spec texts:** default-image, proxy-container and
  subdomain-routing-via-reverse-proxy still show `<project>.<service>`. They
  belong to an OpenSpec change, not this fix; I reported them to the
  coordinator.
