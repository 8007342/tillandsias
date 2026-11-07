# host-tool-discovery

## Why

Operator request 2026-11-02: "Our tooling has been growing organically and has
outgrown its purpose and is likely due a tune up, and renaming and reordering
of our tooling and mcp services, to better group them and show what they do.
host-browser seems to also host local image generation and starting some
sibling containers; I've seen agents struggle to make those connections and
find the tools."

Measured on linux-next 572fed56e (2026-11-02), the way a forge agent sees it:

- The forge registers FOUR MCP servers (`git-tools`, `project-info`,
  `host-browser`, `forge-plan`) in every harness config. The one named
  `host-browser` is a raw socat pipe to the lane socket, and the server behind
  it (`tillandsias-host-services`) advertises 28 non-Cloudflare tools plus 12
  Cloudflare reads: the web preview lifecycle (`publish_local`,
  `service_status`, `service_stop`, `service_reload`, `service_logs`), the
  toolchain image build (`toolchain_prepare`), local image generation
  (`image.generate`), the headless ComfyUI pipeline (`studio.run_workflow`,
  `studio.validate_family`, `studio.finish_pixels`, `studio.contact_sheet`,
  and `studio.key_footage` when opted in), thirteen `browser.*` tools, twelve
  `cloudflare.*` reads and four web-studio co-edit tools (`studio_options`,
  `studio_open`, `studio_changes`, `studio_publish_request`).
- Nothing in that list says which tool starts a sibling container
  (`publish_local` starts a web container; `toolchain_prepare` builds an
  image; `image.generate` starts the engine; `studio.run_workflow` needs a
  studio container that only a relaunch starts) and which only reads.
- Three naming schemes coexist (flat `publish_local`, `service_*`,
  `toolchain_prepare`, `studio_*` beside dotted `browser.*`, `image.*`,
  `studio.*`, `cloudflare.*`), and `studio_*` (visual web studios: GrapesJS,
  Decap, Tina, Puck) collides in meaning with `studio.*` (the ComfyUI image
  pipeline).
- The `initialize` reply carries no `instructions`, so the agent's first
  view of the surface is the flat list.
- The `studio_unavailable` refusal told agents to edit `tillandsias.toml`;
  the project file is `.tillandsias/config.toml`.
- The guidance every harness loads
  (`images/default/config-overlay/mcp/forge-agent-guidance.md`) names only
  `image.generate`; `web-services.md` names only the preview tools; the
  bundled cheatsheets index has no entry for the host tool surface at all.

## What Changes

First slice (this change's implemented tasks):

- Tool names are grouped by what they do: `preview.*` (publish, status,
  stop, reload, logs), `toolchain.*`, `image.*`, `studio.*` (headless
  ComfyUI), `browser.*`, `cloudflare.*`, `webstudio.*` (visual co-edit
  studios). The ten flat names remain callable as deprecated aliases for one
  release and are listed LAST, each description naming its canonical tool.
- Every description says what the tool STARTS (a sibling web container, a
  toolchain image build, the image engine, GPU work in the studio container,
  a host browser window) or that it starts nothing.
- The `initialize` reply carries `instructions`: a grouped index the agent
  sees before any tool; `tillandsias.index {}` returns the same index for a
  harness that drops `instructions`.
- The forge guidance, `web-services.md` and a bundled cheatsheet carry the
  same index and the rename table.
- The `studio_unavailable` remedy names `.tillandsias/config.toml`.

Later slices (tasks only): rename the `host-browser` server registration to
a name for the whole surface with an alias period across the four harness
configs and the Codex registration test; an on-demand `studio.start` so the
forge agent starts the ComfyUI appliance through the socket (order
1969-cfyt's ruling: appliances start on demand from the tool socket, never at
launch, no tray entry); remove the deprecated aliases one release after this
one ships.

## Impact

- `crates/tillandsias-headless/src/mcp_socket.rs`, `host_tools.rs`
  (new), `studio.rs`, `studio_tool.rs`, `tray/mod.rs` (pin tests).
- `images/default/config-overlay/mcp/forge-agent-guidance.md`,
  `images/default/config-overlay/opencode/instructions/web-services.md`,
  `images/default/cheatsheets/tooling/host-tools-index.md` (new, bundled).
- Specs: `host-tool-discovery` (new capability). `host-browser-mcp` and
  `mcp-tool-socket` are unchanged: the browser family keeps its names and
  the socket keeps its transport.
- Compatibility: every existing caller (the `flutter` shim's
  `toolchain_prepare`, the cold-start acceptance's `publish_local`, the
  e2e `service_*` calls) keeps working through the alias table; an older
  forge image against this tray sees its old names listed and callable.
