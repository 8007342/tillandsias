---
tags: [mcp, host-tools, preview, browser, image-generation, studio, cloudflare]
languages: [json]
since: 2026-11-02
last_verified: 2026-11-02
sources:
  - https://modelcontextprotocol.io/specification/2025-06-18/server/tools
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# Host tools index — which MCP tool starts what

@trace spec:host-browser-mcp, spec:mcp-tool-socket, order:1969-7qm7

**Version baseline**: tray 56.11 (order 1969-7qm7)
**Use when**: you are inside a forge and need to know which host tool publishes a preview, opens a browser, generates an image, runs a ComfyUI workflow, reads Cloudflare, or opens a visual web studio — and which of them start a container.

## Provenance

- https://modelcontextprotocol.io/specification/2025-06-18/server/tools — tool descriptors and `initialize.instructions`
- Derived: the tool table is `crates/tillandsias-headless/src/host_tools.rs` (`GROUPS`, `RENAMED`); the same text is the `initialize` reply's `instructions` and the `tillandsias.index {}` result.

## The servers a forge registers

| MCP server | What it is | Tools |
|---|---|---|
| `host-browser` | a pipe to this lane's host socket; despite the name it carries EVERY host tool below | `preview.*`, `toolchain.*`, `image.*`, `studio.*`, `browser.*`, `cloudflare.*`, `webstudio.*`, `tillandsias.index` |
| `forge-plan` | the plan and methodology ledgers, cited | `plan_*`, `methodology_*`, `spec_answer`, `discipline_show`, `msg_*`, `coord` |
| `project-info` | this checkout, read | `search_code`, `grep_code`, `find_files`, `read_file`, `project_*`, `run_command` |
| `git-tools` | the enclave git mirror | `git_*`, `cache_report` |

## Host tools by what they do

| Group | Does | Starts |
|---|---|---|
| `preview.publish` / `.status` / `.reload` / `.stop` / `.logs` | the local WEB preview at `www.<project>.localhost` | `preview.publish` STARTS a sibling web container (static or local Wrangler); the rest act on it |
| `toolchain.prepare` | a shared toolchain image (flutter) | STARTS a one-time image build; the `flutter` command calls it |
| `image.generate` | local image generation (stable-diffusion.cpp) | starts the engine on the host GPU queue on first use; model downloads need the user's consent token |
| `studio.start`, `studio.status` | the ComfyUI studio appliance | start it on demand (idempotent; nothing starts it at forge launch; it stops with the forge) and read whether it runs |
| `studio.run_workflow`, `studio.key_footage` | headless ComfyUI work | queue GPU work in the project's studio container, which must be running (call `studio.start {}` first; no relaunch) |
| `studio.models` | read-only model check | the pinned studio files and whether each is on disk, this tray's model table (compare its `models_tsv` with the checkout's `images/imagegen/models.tsv`), and what each ComfyUI loader lists |
| `studio.validate_family`, `studio.finish_pixels`, `studio.contact_sheet` | family checks, pixel finish, review grid | nothing; no GPU |
| `browser.open` (+12 `browser.*`) | browser windows ON THE HOST for project-local URLs | `browser.open` STARTS a window; `dev: true` adds CDP, eval and tails |
| `cloudflare.scope_probe` (+11 reads) | the operator's Cloudflare account, GET only | nothing; probe first |
| `webstudio.options` / `.open` / `.changes` / `.publish_request` | visual co-edit studios (GrapesJS, Decap, Tina, Puck) | nothing from the lane today; `.open` names the operator command |
| `tillandsias.index` | this table | nothing |

## Deprecated aliases (one release)

`publish_local` → `preview.publish`, `service_status` → `preview.status`, `service_stop` → `preview.stop`, `service_reload` → `preview.reload`, `service_logs` → `preview.logs`, `toolchain_prepare` → `toolchain.prepare`, `studio_options` → `webstudio.options`, `studio_open` → `webstudio.open`, `studio_changes` → `webstudio.changes`, `studio_publish_request` → `webstudio.publish_request`. Same schema, same behaviour; listed last.

## Common pitfalls

- `studio.*` is ComfyUI; `webstudio.*` is GrapesJS/Decap/Tina/Puck. They are not the same studio.
- `studio_unavailable` means the ComfyUI container is not running; starting it from the socket on demand is order 1969-cfyt, not yet shipped.
- The forge has no browser binary: `browser.open` is the only way to see a page.

Studio notes (kumbia forge, 2026-11-03): BiRefNet's alpha is soft (interior pixels read 254, not 255), so threshold it before treating it as a cutout mask. Only `~/.cache/tillandsias-project` survives a forge restart; anything else written in the forge is gone after it.
