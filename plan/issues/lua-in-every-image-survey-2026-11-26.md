# Lua in every image: survey (2026-11-26)

Asked by macuahuitl on 2026-11-26. The operator ruled the same day: Lua first, then Rust, then Go, in every container; Python only where interop forces it. This row is survey only. No image is changed here.

Method: read every `images/*/Containerfile*` on origin/linux-next. For each one, check the final `FROM` and whether it installs a Lua runtime (lua, lua5.x, luajit) or copies `tillandsias-plan`, which runs Lua through `script run`. Mentions of `scripts/lua/*` in build comments are host-side build steps and do not count.

## Images with a Lua runtime today (5)

| image | how |
|---|---|
| default (the forge) | Containerfile.base installs `lua lua-filesystem lua-lpeg`, and Containerfile adds the static musl `policy-bin/tillandsias-plan` |
| studio-decap, studio-grapesjs, studio-puck, studio-tina | the final stage is `FROM ${FORGE_IMAGE}`, so each inherits the forge's runtime |

## Images without one (17 rows, one each)

| order | image | final base | in-image scripts | note |
|---|---|---|---|---|
| 2413-ucx2 | audio-studio (Containerfile) | python:3.12.16-slim-bookworm | no shell scripts; 1 .py | Python app image; Lua would sit beside it for any glue, the app stays Python (interop). |
| 2413-gq2n | builder (Containerfile) | fedora-minimal:44 | none | dnf base: the lua package (and lua-filesystem/lua-lpeg as the forge base has) is one install line. |
| 2413-prwd | chromium (Containerfile.core, Containerfile.framework (FROM core)) | fedora-minimal:44 | 2 | One packet for both: framework inherits core, so the runtime goes in core. |
| 2413-dvmn | enclave-fetch (Containerfile) | alpine:3.22 | none | apk lua5.4 is small; or the static musl tillandsias-plan. |
| 2413-3bc5 | flutter (Containerfile) | debian:bookworm-slim (pinned digest) | none | apt lua5.4. |
| 2413-thcz | git (Containerfile (vault stage + alpine:3.20 final)) | alpine:3.20 | 18 .sh (entrypoint, receive hooks, relay, seed, vault-agent) | Largest shell surface outside the forge; the 2374-wy4f question named git and inference together. Ships ports only after the runtime lands. |
| 2413-yu6p | imagegen-corridorkey (Containerfile) | python:3.12.16-slim-bookworm | none | Python app image (interop); Lua for glue only. |
| 2413-y9jz | imagegen-studio (Containerfile) | python:3.12.16-slim-bookworm | none; 7 .py | Python app image (ComfyUI custom nodes are interop-forced Python). |
| 2413-pg82 | imagegen (Containerfile (fedora:44), Containerfile.cuda (nvidia/cuda:13.3.1 ubuntu24.04 runtime)) | fedora:44 / cuda ubuntu24.04 | none | Two bases, one packet: dnf lua and apt lua5.4. |
| 2413-jprz | inference (Containerfile) | fedora-minimal:44 | 9 .sh | 2374-wy4f lists the nine and which are portable; the operator's ruling today answers its question. |
| 2413-2wnc | proxy (Containerfile) | alpine:3.22 | 2 .sh (entrypoint, squid-supervisor) | Lua mentions in it are build-time scripts/lua/*, not an in-image runtime. |
| 2413-i8j7 | router (Containerfile) | caddy:2-alpine | 2 .sh (entrypoint, router-reload) | apk lua5.4 on the caddy alpine base. |
| 2413-qewe | vault (Containerfile) | hashicorp/vault:1.18 | 1 .sh (entrypoint) | Upstream vault image (alpine-based); security boundary: keep the addition minimal and say what it adds. |
| 2413-jvhh | warp (Containerfile) | debian:bookworm-slim | 1 | apt lua5.4. |
| 2413-wb7i | web-wrangler (Containerfile) | node:22.19.0-bookworm-slim (pinned digest) | 1 | Node app image; apt lua5.4 for glue. |
| 2413-kmv8 | web (Containerfile) | alpine:3.20 | 1 .sh (entrypoint) | apk lua5.4. |
| 2413-fbzp | webkit (Containerfile) | ubuntu:24.04 (pinned digest) | 2 | apt lua5.4. |

## Not images

images/dmg, images/models, images/selinux and images/vm have no Containerfile: they hold packaging, model registers, policy and VM recipes. No row was filed for them.

## Choices each row makes, not this one

- **Runtime:** the distro Lua (small, and needs lua-filesystem/lua-lpeg to match the forge) or the 10.9 MB static musl `tillandsias-plan`. The plan binary carries the proc/fs harness the ported scripts use. 2374-wy4f lists the build paths that name `images/default/policy-bin` as the binary's only destination.
- **Ports:** each row adds the runtime only. Porting an image's shell scripts is separate work, once the runtime is there.
- **Size:** each row reports the image size before and after.
