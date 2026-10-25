# Proposal — local-image-generation

Epic: `1874-4b88` (desired_release v0.6, priority p2). Slices: `1874-b9tg`
(imagegen image), `1874-bair` (tier table and classifier), `1874-h9ns`
(pinned model fetch into the cache), `1874-kkrc` (`image.generate` on the
host MCP socket), `1874-p8w7` (one-tier-up offer and consent), `1874-qyfv`
(macOS Metal host helper), `1874-s2q3` (WSL2 and floor-tier CPU lanes),
`1874-zry8` (optional ComfyUI studio). Depends on `1871-47ex` (the shared
image-result schema: saved path plus metadata, never inline base64).

## Why

Operator direction (2026-10-25): forge agents need a local image tool
(icons, sprites, mock-up art, placeholder photography) that works on every
fleet device with no cloud account, picks a model that fits the hardware
without asking, and asks the user only before a much longer, higher-quality
run with a larger model.

Operator rulings (2026-10-25): output goes to a shared scratch directory
destroyed on forge teardown; images are generated exactly as the agent
asks; only permissive/open model licences with no revenue caps; always
start with the smallest model and offer one tier larger at a time with a
curated, honest sentence and no raw sizes; only free Cloudflare and free
GitHub are acceptable metered services. Claude, OpenCode and Codex must see the same tool
with the same result contract.

SOURCE READ (2026-10-25, trunk `054751d4e`):

- The host MCP tool socket (`mcp_socket.rs` `fn handle_mcp_jsonrpc`) already
  serves `publish_local`, `service_*` and `browser.*` to every forge lane, and
  all three agent harnesses reach it through the one `host-browser` bridge
  (`images/default/config-overlay/mcp/host-browser.sh`, wired in the Claude
  `mcp.json`, the OpenCode `config.json` and Codex's registration). A new
  tool name on that dispatcher is visible to all three with no per-agent
  wiring.
- Images are built on first use by `fn ensure_image_exists` (per-image
  flock, detach decision, slow-work announce); `fn ensure_window_image` in
  `browser_open.rs` is the precedent for a tool that builds its image lazily.
- Hardware routing already exists: `accel_probe.rs` publishes the
  `accel_class` envelope (`workstation-gpu | mobile-npu | hybrid-gpu-npu |
  cpu-only`) plus VRAM/RAM facts, and the LLM side maps those to T0–T5 in
  `images/inference/tiers/tier-table.tsv`. The inference image already ships
  the Vulkan userspace (order 917-zkge) and the NVIDIA CDI path
  (`scripts/nvidia-cdi-ensure.sh`).
- Models live in `cache_root().join("models")` (`tillandsias_core::cache_root`),
  bind-mounted, never baked into an image.
- There is no image-generation code anywhere in the tree.

## What Changes

- A new `imagegen` image built on first use from a pinned
  stable-diffusion.cpp tag (MIT), running `sd-server` with Vulkan + CPU
  backends (CUDA variant on NVIDIA hosts), on the enclave network, no egress.
- A declarative imagegen tier ladder (I0–I3), permissive licences only,
  smallest first; the accel envelope sets only the ceiling.
- Models fetched on first use into `cache_root()/models/imagegen/` by pinned
  URL + sha256, never into an image or a ramdisk.
- One MCP tool, `image.generate`, on the host socket; results follow the
  1871-47ex schema and are written to the shared `/work/tmp/imagegen/`
  scratch dir (imagegen + forge), destroyed on forge teardown.
- A one-tier-up offer: each result may offer exactly the next larger tier
  with a curated sentence and a host-minted single-use token.
- macOS: a host-native Metal `sd-server` helper (the VM has no Metal).
- An optional `imagegen-studio` (ComfyUI) image, off by default.

## Capabilities

### New Capabilities

- `image-generation`: the imagegen engine, tier ladder, model cache, result
  contract and tier-up offer.
- `imagegen-studio`: the optional ComfyUI authoring image.

### Modified Capabilities

- `mcp-tool-socket`: the socket also carries `image.*` tools.

## Impact

`crates/tillandsias-headless` (mcp_socket dispatch, a new imagegen module,
accel envelope consumer), `images/imagegen/` (new), forge scratch mount, `images/image-pins.yaml`,
macOS tray helper launch, forge agent instructions. No change to the LLM
inference image or its tiers.
