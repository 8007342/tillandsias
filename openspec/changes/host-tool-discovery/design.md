# Design — host-tool-discovery

## Context

One lane socket serves every host-side tool (order 779-3trn composed the
browser server into the host-services dispatcher; 1874-kkrc, 1956-x7xp,
1959-xsy5, 1772-irs3 and 1860-auhm each appended a family). The forge
registers that socket as the MCP server `host-browser` in four harness
configs (`claude/mcp.json`, `opencode/config.json`,
`antigravity/mcp_config.json`, `codex/register-experts.sh`). The server
name is a registration label; the tool names are what the agent reads.

## Decisions

1. **Group by verb, not by crate.** The prefix says what the tool acts on:
   `preview.*` the local web preview; `toolchain.*` a shared toolchain image;
   `image.*` local generation; `studio.*` the headless ComfyUI appliance;
   `browser.*` host browser windows; `cloudflare.*` the operator's account
   (reads); `webstudio.*` the visual co-edit studios. `studio.*` keeps its
   meaning (ComfyUI, the larger and older family); the four co-edit tools
   move to `webstudio.*` because they open GrapesJS/Decap/Tina/Puck, not
   ComfyUI, and the collision was the measured confusion.
2. **Aliases resolve before dispatch.** `host_tools::canonical` rewrites a
   deprecated flat name to its canonical name at the top of `tools/call`;
   the dispatcher's match arms only know canonical names, so the two names
   cannot diverge in behaviour. The alias table is one `const`.
3. **Aliases are listed, last, and say so.** An agent whose instructions
   still say `publish_local` must find it; an agent reading the list must
   not be led to it. Each alias descriptor is the canonical one with the
   name swapped and the description prefixed `Deprecated alias of <canonical>`.
   They are appended after every canonical tool, in table order.
4. **The index is rendered from one table.** `initialize.instructions`,
   `tillandsias.index` and the tests all read `host_tools::GROUPS`, so the
   text the agent sees first and the list it then reads cannot disagree.
5. **"What it starts" is a description invariant.** A fixture asserts the
   verbs: `preview.publish` STARTS a sibling web container,
   `toolchain.prepare` STARTS a one-time build, `studio.run_workflow` names
   the studio container, `webstudio.open` starts nothing from the lane, and
   the read-only tools say "Starts nothing".
6. **The server name is not renamed in this slice.** The label appears in
   four harness configs, the Codex registration test, three Lua guards, the
   forge intro skill and `lib-common.sh`. The `instructions` text names the
   registration (`host-browser`) so the agent can connect the label to the
   surface today; the rename with a one-release alias registration is a
   task of its own.

## Alternatives considered

- Listing only the canonical names and accepting the aliases silently:
  breaks `tools/list` assertions in the cold-start acceptance and the e2e
  preview test, and hides the alias from an agent whose project
  instructions name it.
- Splitting the socket into several MCP servers (one per group): each
  server is a socat pipe plus a registration in four configs; the agent
  gains nothing a prefix does not give, and the Codex env plumbing
  (`TILLANDSIAS_CONTROL_SOCKET`) would be repeated per server.
