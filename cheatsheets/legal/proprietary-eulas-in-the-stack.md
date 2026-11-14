---
tags: [licence, eula, proprietary, nvidia, cuda, cloudflare, warp, claude-code, terms-of-service, click-through]
languages: []
since: 2026-10-31
last_verified: 2026-10-31
sources:
  - https://hub.docker.com/r/nvidia/cuda
  - https://developer.download.nvidia.com/licenses/NVIDIA_Deep_Learning_Container_License.pdf
  - https://www.cloudflare.com/application/terms/
  - https://registry.npmjs.org/@anthropic-ai/claude-code/latest
  - https://www.anthropic.com/legal/commercial-terms
  - https://www.anthropic.com/legal/consumer-terms
  - https://registry.npmjs.org/@openai/codex/latest
  - https://registry.npmjs.org/opencode-ai/latest
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---
# Proprietary EULAs in the Tillandsias stack

@trace spec:cheatsheet-tooling
@cheatsheet legal/combining-licences-without-conflict.md, legal/runtime-acknowledgement-vs-acceptance.md

**This is not legal advice.** These are the three non-open components found
in `images/` on 2026-10-31 whose terms say the **user** agrees by installing
or using. Each is fetched by the user's machine, never shipped by us; that is
the only arrangement their terms allow.

**Use when**: bumping any of these, considering bundling one, or wording its
first-launch card.

## Inventory

| Component | Where | Terms | Key restriction | Tier |
| --- | --- | --- | --- | --- |
| `docker.io/nvidia/cuda:13.3.1-{devel,runtime}-ubuntu24.04` | `images/imagegen/Containerfile.cuda` (the CUDA lane only; the Vulkan lane is Fedora) | NVIDIA Deep Learning Container License v. 14 Sept 2021 | 4.c "you may not distribute or sublicense the CONTAINER as a stand-alone product"; 4.a proprietary parts run only on NVIDIA GPUs; 4.g no use that subjects it to an open-source licence; 4.h no Critical Applications; 2.c derived containers must carry terms at least as protective | accept, never bundle |
| Cloudflare WARP client (`pkg.cloudflareclient.com`, `WARP_VERSION=2026.7.1377.0`) | `images/warp/Containerfile` | Cloudflare Application Terms | "By downloading, installing, accessing, or using the Application you agree to be bound by this Agreement"; licensed not sold; no reverse engineering; non-transferable per-device licence | accept, never bundle |
| `@anthropic-ai/claude-code` (npm, `license: "SEE LICENSE IN README.md"`) | installed at FIRST_RUN by `images/default/lib-common.sh` `_require_harness` | Anthropic Commercial Terms of Service (or Consumer Terms for personal accounts), per the README | usage policy and account terms apply; not open source | accept once per installation; the user already agreed at account sign-up, the card records that this component is under those terms |
| `@openai/codex` (npm) | same install path | Apache-2.0 | none from the package; OpenAI account terms govern the API | acknowledge |
| `opencode-ai` (npm) | same install path | MIT | none | acknowledge |

## NVIDIA Deep Learning Container License, the parts that bind us

Text read from the PDF on 2026-10-31 (v. September 14, 2021):

- Acceptance: "By using the CONTAINER, you affirm that you have reached the
  legal age of majority, you accept the terms of this license, and you take
  legal and financial responsibility for the actions of your permitted
  users." The Docker Hub page adds: "By pulling and using the CUDA images, you
  accept the terms and conditions of these licenses."
- Grant 1.c permits a derived container "that includes the entire CONTAINER
  plus other software with primary functionality", distributable only under
  Section 2, which requires terms "at least as protective" and the notice
  "This software contains source code provided by NVIDIA Corporation." in
  derived source.
- 4.c forbids distributing the container stand-alone; 4.g forbids causing it
  to become subject to an open-source licence; 4.h disclaims Critical
  Applications; 4.i is an indemnity by the user.
- 7: open-source components inside keep their own licences; NVIDIA archives
  the GPL sources at `developer.download.nvidia.com/compute/cuda/opensource/image`.

Reading for Tillandsias: the imagegen CUDA image is built locally and run
locally, which is grant 1.a. Publishing that image would need Section 2
compliance **and** our own terms to carry NVIDIA's restrictions, which is
exactly what 4.g makes awkward for an open project. Do not push it.

## Cloudflare WARP

The Application Terms govern "the Application" (the page does not name WARP,
but lists a WARP abuse contact and Cloudflare for Teams). The user accepts by
installing. The `images/warp` lane installs the client from Cloudflare's apt
repository on the user's machine. No redistribution by us. Card: accept,
link to the terms, note that the client talks to Cloudflare's network.

## Claude Code

The npm package declares no SPDX licence; the README points to the
Commercial Terms of Service and Privacy Policy. The forge installs it at first
run for the user's own account. The honest card says "this is Anthropic's
software under Anthropic's terms, which you agreed to with your account; here
is the link", records that, and does not pretend Tillandsias can grant any
rights to it. Same treatment for any future proprietary agent CLI.

## Common pitfalls

- An npm `license` field of "SEE LICENSE IN ..." is not a licence id; the
  register must store the terms URL and the text hash, not a guessed SPDX id.
- The CUDA **Dockerfiles** are BSD-3-Clause; the **images** are under the
  EULA. Do not let the former's badge answer the latter's question.
- WARP's terms are a web page, not a file in the package; pin the fetch date
  and hash the page text in the register.
- A Containerfile `FROM` of a proprietary image makes every derived image
  proprietary in distribution terms, whatever our own layers are.

## Provenance

- <https://hub.docker.com/r/nvidia/cuda> — "By pulling and using the CUDA images, you accept the terms and conditions of these licenses." (fetched 2026-10-31)
- <https://developer.download.nvidia.com/licenses/NVIDIA_Deep_Learning_Container_License.pdf> — sections 1, 2, 4, 7 read 2026-10-31
- <https://www.cloudflare.com/application/terms/> — acceptance sentence quoted (fetched 2026-10-31)
- <https://registry.npmjs.org/@anthropic-ai/claude-code/latest> — `"license": "SEE LICENSE IN README.md"`, version 2.1.316 on 2026-10-31
- <https://www.anthropic.com/legal/commercial-terms>, <https://www.anthropic.com/legal/consumer-terms> — the terms the README names
- <https://registry.npmjs.org/@openai/codex/latest> — `"license": "Apache-2.0"`, 0.166.0 on 2026-10-31
- <https://registry.npmjs.org/opencode-ai/latest> — `"license": "MIT"`, 1.19.5 on 2026-10-31
- Derived (not provenance): `images/imagegen/Containerfile.cuda`, `images/warp/Containerfile`, `images/default/lib-common.sh:3597-3732` read 2026-10-31.

## See also

- `legal/combining-licences-without-conflict.md`
- `legal/runtime-acknowledgement-vs-acceptance.md`
- `legal/busl-1-1-hashicorp-vault.md`
