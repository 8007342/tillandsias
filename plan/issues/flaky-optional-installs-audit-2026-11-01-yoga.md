# Flaky optional installs — audit (1951-vv5m)

Filed by yoga, 2026-11-01, for packet 1951-vv5m (operator direction relayed by
macuahuitl-fedora). Citations are by symbol and file, never by line.

**Method.** `git grep` on linux-next 752fec60d over `images/**` and
`scripts/install*.sh` for pip / npm / cargo / go installs, curl / wget fetches,
package-manager installs and `git clone`, comment lines dropped: 106 hits. Calls
to enclave-local endpoints (vault, router, inference, embed, the lane socket,
localhost) were then removed by pattern. **This is an upper bound on sites, not
a census of behaviour**: a fetch spelled another way (a Rust `reqwest` call, a
`podman pull`, a helper that wraps curl) is not in it. Host-side Rust provisioning
(`crates/tillandsias-headless`: image pulls, the imagegen model fetch in
imagegen_models.rs, the inference model pull) is NOT covered here and is the
next pass.

## Classification rule

- **required** — the image or lane has no purpose without it (its base packages,
  the program the image exists to run, the project checkout). Blocking with a
  named verdict is correct.
- **flaky-optional** — a developer convenience the forge can reach ready
  without (linters, LSPs, cargo dev tools, SDKs a project may not use, model
  warm-ups). These move to the background family with a first-use shim.

## Build time (Containerfiles)

| Site | What | Class | Today |
|---|---|---|---|
| images/default/Containerfile.base, microdnf step | base OS packages | required | blocks, correct |
| images/default/Containerfile.base, Python/dev-tools step (`PIP_STALL_BUDGET_S`) | pip3 pyright, bandit; npm -g typescript, typescript-language-server, prettier, eslint, markdownlint-cli | **flaky-optional** | **blocks the forge-base build up to 600 s, then fails it** (1771-4iw3 bounded it; macuahuitl stall 2026-11-01) |
| images/chromium/Containerfile.core, .framework microdnf steps | browser + fonts | required | blocks, correct |
| images/chromium/Containerfile.framework, npm -g playwright | browser automation (unpinned) | required for that image | blocks; also unpinned |
| images/webkit/Containerfile, node tarball, playwright npm, WebKit zip | the image's purpose | required | blocks, correct |
| images/flutter/Containerfile, SDK tarball / git clone fallback | the image's purpose | required | blocks, correct |
| images/imagegen/Containerfile(.cuda), sd.cpp git clone | the image's purpose | required | blocks, correct |
| images/imagegen-studio/Containerfile, ComfyUI clone + pip | the image's purpose | required | blocks, correct |
| images/inference/Containerfile, microdnf (vulkan, caddy) | runtime | required | blocks, correct |
| images/proxy, git, router, vault, web Containerfiles, apk | runtime | required | blocks, correct |
| images/warp/Containerfile, cloudflare-warp apt repo | the image's purpose | required | blocks, correct |
| images/web-wrangler/Containerfile, npm ci | the image's purpose | required | blocks, correct |
| images/vm/Recipefile, dnf | VM base | required | blocks, correct |

## Forge first run (images/default/lib-common.sh, called from entrypoint-*.sh)

| Site | What | Class | Today |
|---|---|---|---|
| ensure_forge_prebuilt_tools → install_prebuilt (18 GitHub release fetches, 120 s each, 2 retries) + ensure_dart_sdk (300 s) + marksman | cargo dev tools, actionlint, vale, wasmtime, Dart SDK, marksman | **flaky-optional** | backgrounded (`&`) in entrypoint-forge-claude.sh, -codex.sh, -opencode.sh, entrypoint-terminal.sh; **foreground** in entrypoint-forge-antigravity.sh and entrypoint-forge-opencode-web.sh. No status file and no shim anywhere: a call during the install is `command not found` |
| ensure_openspec_pinned (npm -g @fission-ai/openspec) | OpenSpec CLI | **flaky-optional** | **foreground** in entrypoint-forge-claude.sh, -opencode.sh, -opencode-web.sh, entrypoint-terminal.sh |
| ensure_forge_harnesses → _require_harness (npm -g `<harness>@latest`), claude_validate_or_rollback (claude.ai/install.sh), require_antigravity | the lane's own agent | required for its lane | backgrounded; the tray already reports "initializing" while it runs (tillandsias-headless main.rs, the attach-readiness comment) |
| warm_tier_model_fail_soft (curl, 300 s) | inference model warm-up | flaky-optional | fail-soft, `|| true`; check whether its caller waits |
| lib-common.sh project checkout (`git clone git://<mirror>/<project>`) | the workspace | required | blocks with FATAL, correct |
| images/default/brew-shim-exec.sh | brew formulae on first use | flaky-optional | **already the target pattern**: a first-use shim with a bounded install and a named timeout message. Reuse its shape |

## Inference container (runtime)

| Site | What | Class | Today |
|---|---|---|---|
| images/inference/entrypoint.sh, _engine_wanted_backends (GitHub probe 15 s, engine fetch 600 s) | inference engine backends | flaky-optional for the forge | in the inference container's own start; does not gate forge ready directly — confirm |
| images/inference/llama-server-lane.sh, tillandsias_llama_gguf_ensure (1800 s) | GGUF model | flaky-optional | per-lane, on demand |

## Host installers

| Site | What | Class |
|---|---|---|
| scripts/install.sh, scripts/install-macos.sh | release binary + checksums | required (the install itself) |
| scripts/install-chromium.sh | browser download | required for that script |

## Findings that decide 1951-vv5m's scope

1. **The incident site is the only flaky-optional install that runs at image
   BUILD time.** Every other build-time fetch is required for its image. So the
   build-time change is one move: take the Containerfile.base pip3 + npm
   dev-tools step out of the build and into the first-run background family.
2. **A background family half-exists already** (ensure_forge_prebuilt_tools
   behind `&` in four entrypoints) but has no status files and no shims, runs in
   the foreground in two entrypoints, and ensure_openspec_pinned runs in the
   foreground in four. The packet's work is: one family runner with a status
   file per install, every entrypoint calling it in the background, and a
   generated shim per tool modelled on brew-shim-exec.sh.
3. Not yet audited: host-side Rust provisioning (podman pulls, imagegen and
   inference model fetches) and whether the tray menu freeze on macuahuitl is
   the build blocking the tray's event loop. That second one is its own defect:
   a slow build must not freeze the menu, whatever the install.
