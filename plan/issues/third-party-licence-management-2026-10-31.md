# Third-party licence management — findings and proposal (2026-10-31)

@trace order:1940-lcns, spec:approval-attestation, spec:approval-record, spec:first-use-download-consent

Operator direction (2026-10-31): research the licence acceptance of third-party
software we install; use the hardware-key signatures from the fingerprint and
Windows Hello devices as proof of licence acceptance; on first launch of a
component with a licence show Mācron as a lawyer with a briefcase and a prompt
along the lines of "This is third-party software with its own licence";
recognise the software being used and have the user agree at runtime; add
legal cheatsheets for referencing multiple licences without conflict; build a
licence management system beside the software stack manifest if needed.

**Not legal advice.** Findings are read from licence texts and this
repository; the cheatsheets under `cheatsheets/legal/` carry the provenance.

## Findings

### F1. We mostly fetch; we redistribute only what rides in the release binary

- `scripts/build-image.sh` has no `podman push`; nothing in `scripts/` or
  `.github/` publishes an image (`grep -rlE 'ghcr\.io|podman push|docker push'`
  returned nothing on 2026-10-31). Every container is built on the user's
  machine from upstream `FROM` bases and packages.
- ollama self-installs from GitHub releases at container start
  (`images/inference/entrypoint.sh:399`, `OLLAMA_VERSION=v0.34.0`); agent CLIs
  are installed at FIRST_RUN by `images/default/lib-common.sh`
  `_require_harness` (`opencode-ai`, `@openai/codex`,
  `@anthropic-ai/claude-code`, `@fission-ai/openspec`); cargo tools, Dart SDK
  and model files likewise.
- The release binary embeds `images/` via `build.rs` (Containerfiles, scripts,
  the derived `images/default/cheatsheets/` tree). GrapesJS (PR #755) is
  fetched at image build time, so it is also "fetch" unless the image is pushed.
- Consequence: the operator's "not redistributing ourselves" holds for every
  third-party **binary** today. What never stops applying regardless of
  distribution: **use restrictions** (OpenRAIL Attachment A, BUSL Additional
  Use Grant, NVIDIA container EULA) and **click-wrap EULAs** that say the user
  agrees by installing (NVIDIA, Cloudflare WARP). Those are the real reason
  for a runtime prompt.

### F2. Click-through is meaningless for permissive licences and required-by-text for the restrictive ones

MIT/BSD/Apache/MPL/GPL grant use without any acceptance (GPLv3 section 9 says
so outright). A card that demands acceptance of MIT would be false. OpenRAIL
III.5 says downstream users must be given notice of the restrictions; the
NVIDIA container licence and Cloudflare terms say the user accepts by using.
So the design is **two tiers decided per register row**: `acknowledge`
(disclosure, once, no signature, aggregated per image) and `accept`
(blocking, signed). A third `refuse` tier covers non-commercial and gated
licences, as the model register already does.

### F3. Hardware-key signing: reuse the approval broker; fprintd cannot sign

`openspec/changes/os-verified-approval-gates/design.md` D1-D4 already enrols a
per-host hardware key (Secure Enclave on macOS, Windows Hello KeyCredential or
WebAuthn ES256 on Windows, FIDO2 `ed25519-sk` on Linux, polkit-verified
software key fallback) and emits SSHSIG statements with a `strength` field.
A licence acceptance is a **new statement kind in a new namespace**
(`tillandsias-licence-acceptance@v1`), not a second key system. Verified
2026-10-31: `net.reactivated.Fprint.Device` has no signing method; its
`VerifyStatus` signal returns `verify-match`/`verify-no-match` only. On a
Linux host with just a fingerprint reader the record is honestly
`strength: software-password` (polkit `auth_self` may use fprintd, the key is
software). Windows Hello does sign (`KeyCredential.RequestSignAsync`: "Prompts
the user to cryptographically sign data using their key credential").

The signature proves **assent on this device** (non-repudiation to us), not
legal enforceability of the licence; cheatsheet
`legal/runtime-acknowledgement-vs-acceptance.md` states the E-SIGN/eIDAS
framing.

### F4. Inventory of third-party components found in `images/` (2026-10-31)

Licence ids are from the sources cited in the cheatsheets; "unverified" means
read from memory of the project, not fetched today.

| Component | Where | Licence | Distribution | Tier |
| --- | --- | --- | --- | --- |
| Fedora Minimal 44 / Fedora 44 packages | builder, chromium-core, default-base, inference, imagegen | mixed OSI (SPDX per `rpm -q --qf %{LICENSE}`), GPL/LGPL among them | fetched | acknowledge (per image) |
| Debian bookworm-slim, Ubuntu 24.04, Alpine 3.20/3.22 packages | flutter, warp, webkit, git, web, proxy, router | mixed OSI | fetched | acknowledge (per image) |
| nix | builder | LGPL-2.1-or-later (unverified) | fetched | acknowledge |
| chromium-headless, chromium (Fedora) | chromium core/framework | BSD-3-Clause plus bundled third-party | fetched | acknowledge |
| nodejs, npm | chromium-framework, default-base, webkit (nodejs.org 22.23.3), web-wrangler (node:22.19.0) | MIT | fetched | acknowledge |
| playwright | chromium-framework (unpinned `latest`), webkit 1.63.0 | Apache-2.0 | fetched | acknowledge |
| WebKit build (Playwright CDN, revision 2359) | webkit | LGPL-2.1 / BSD-2 mixed (unverified) | fetched | acknowledge |
| typescript 6.0.3 | default-base | Apache-2.0 | fetched | acknowledge |
| typescript-language-server 5.3.0, prettier 3.8.3, eslint 10.4.1, markdownlint-cli 0.48.0 | default-base | MIT | fetched | acknowledge |
| pyright, bandit (pip) | default-base | MIT, Apache-2.0 | fetched | acknowledge |
| opencode-ai 1.19.5 | FIRST_RUN | MIT (npm, fetched 2026-10-31) | fetched | acknowledge |
| @openai/codex 0.166.0 | FIRST_RUN | Apache-2.0 (npm, fetched) | fetched | acknowledge |
| @anthropic-ai/claude-code 2.1.316 | FIRST_RUN | `SEE LICENSE IN README.md` → Anthropic Commercial/Consumer Terms (not open source) | fetched | **accept** (disclosure + record) |
| @fission-ai/openspec | FIRST_RUN | MIT (unverified) | fetched | acknowledge |
| cargo tools, nextest, actionlint, vale, wasmtime, Dart SDK | FIRST_RUN | MIT/Apache-2.0 family; wasmtime Apache-2.0 WITH LLVM-exception; Dart BSD-3 (unverified) | fetched | acknowledge |
| Flutter SDK 3.47.7 | flutter | BSD-3-Clause | fetched | acknowledge |
| HashiCorp Vault 1.18 (image + binary copied into git image) | vault, git | **BUSL-1.1** (LICENSE at v1.18.0 fetched 2026-10-31; Additional Use Grant: production use allowed unless offered hosted/embedded to compete with HashiCorp's paid Vault) | fetched | **accept** |
| stable-diffusion.cpp `master-1015-e41fbcf` + ggml | imagegen | MIT (unverified) | fetched, built locally | acknowledge |
| nvidia/cuda 13.3.1 devel/runtime ubuntu24.04 | imagegen (CUDA lane) | **NVIDIA Deep Learning Container License** (click-wrap, no stand-alone redistribution, GPU-only, no Critical Applications) | fetched | **accept**, never bundle |
| python:3.12.16-slim-bookworm | imagegen-studio | PSF-2.0 + Debian | fetched | acknowledge |
| ComfyUI v0.40.0 | imagegen-studio | **GPL-3.0** (LICENSE fetched 2026-10-31) — separate process, no linking to our code | fetched | acknowledge (note copyleft if ever bundled) |
| torch 2.10.0+cu128, torchvision | imagegen-studio | BSD-3-Clause; the `+cu128` wheels pull `nvidia-*` pip packages under the **NVIDIA EULA** (unverified which) | fetched | **accept** (via the CUDA card) |
| ollama v0.34.0 | inference (self-install) | MIT | fetched | acknowledge |
| caddy | inference, router | Apache-2.0 | fetched | acknowledge |
| squid | proxy | GPL-2.0-or-later | fetched | acknowledge |
| Cloudflare WARP client 2026.7.1377.0 | warp | **Cloudflare Application Terms** (click-wrap, licensed not sold) | fetched | **accept** |
| wrangler 4.42.0 | web-wrangler | MIT OR Apache-2.0 (unverified) | fetched | acknowledge |
| GrapesJS 0.23.8 | web-studio-grapesjs (PR #755) | BSD-3-Clause | fetched at image build | acknowledge |
| Decap CMS, Puck (upcoming 1862, 1864) | studio lanes | MIT | fetched | acknowledge |
| TinaCMS, Onlook (upcoming 1863, 1865) | studio lanes | Apache-2.0 | fetched | acknowledge |
| FLUX.1-schnell GGUF (ae, clip_l, T5-XXL, Q4/Q8) | models register | Apache-2.0 | fetched | acknowledge |
| SDXL-Lightning 4step, SDXS-512-0.9 | models register | **openrail++** (Attachment A use restrictions) | fetched | **accept** |
| Qwen2.5 0.5B/7B/14B Instruct, Qwen2.5-Coder 7B/32B (ollama + llama-server tiers) | inference tiers | Apache-2.0 | fetched | acknowledge — **not in any register today** |
| nomic-embed-text | inference | Apache-2.0 | fetched | acknowledge — not in any register |

### F5. Components whose licence is a real problem or a near miss

1. **nvidia/cuda images** (imagegen CUDA lane): proprietary click-wrap with
   field-of-use (GPU-only, no Critical Applications), no stand-alone
   redistribution, and 4.g forbids use that would subject the container to an
   open-source licence. Fine as a local fetch; **must never be pushed or
   bundled**, and the user has to see and accept it.
2. **HashiCorp Vault 1.18**: BUSL-1.1, not open source. Our enclave-local use
   fits the Additional Use Grant on today's facts; offering the enclave Vault
   to third parties or marketing Tillandsias as a secrets product would not.
3. **Cloudflare WARP**: proprietary, accepted by installing; the client talks
   to Cloudflare's network. Accept tier, never bundle.
4. **Claude Code**: proprietary under account terms; acceptable, but the card
   must not claim we license it.
5. **OpenRAIL++ models**: Attachment A binds the user; accept tier with the
   text shown.
6. **Near miss**: `qwen2.5:3b` (mentioned in `images/inference/decode-floor-pin.sh`
   and `gpu-stall-watchdog.sh` comments) is under the Qwen Research licence
   (non-commercial-style), unlike the Apache-2.0 sizes that are pinned. It is
   not in any tier table today; the component register must refuse it if it
   ever returns. Same for `qwen2.5:72b`.
7. **Gap**: the LLM tier tables (`images/inference/tiers/*.tsv`) pin models
   without any licence column; the media register covers only
   `images/models/`. The component register closes this.
8. **ComfyUI is GPL-3.0**: harmless as a separate container process; it would
   become a problem only if any of our code were linked into it or shipped
   together as one program.

## Proposed design

### D1. A component licence register beside the model one

`images/licence-register.tsv` (sibling of `images/models/licence-register.tsv`,
same TAB grammar, same no-interpreter rule), one row per third-party
component, generated candidates by a Lua scanner over Containerfiles and
tier tables, reviewed by hand. Columns:

```
component  version  source  kind  licence_id  licence_url  licence_sha256  distribution  tier  reaccept_on  image  verified
```

- `kind`: `base-image | distro-packages | npm | pip | binary | git-build | model | cli`
- `licence_id`: SPDX id, or `LicenseRef-<stable-name>` for EULAs and RAIL tags
- `licence_sha256`: sha256 of the text shown to the user (the card refuses on mismatch)
- `distribution`: `fetched | redistributed` (the first `redistributed` row for a non-permissive licence trips a gate)
- `tier`: `acknowledge | accept | refuse`
- `reaccept_on`: `text | version | never`
- `verified`: ISO date and the URL the id was read from

A checker `scripts/lua/check-component-licence-register.lua` (a sibling of
`check-model-licence-register.lua`) refuses: a Containerfile `FROM`, `npm
install -g`, `pip install`, `git clone`/tarball URL or tier-table row with no
register row; any `refuse` row that is referenced; any `redistributed` row
whose licence is in the accept family; any `accept` row with an empty
`licence_sha256`. The distro-packages rows carry the image's rpm/apk/dpkg
licence census hash rather than per-package rows, so the forge-base's
hundreds of packages are one row.

### D2. Aggregated notices

`tillandsias-policy generate-third-party-notices` renders
`THIRD-PARTY-NOTICES.md` from the register for the About page and the
release tarball (the release binary is the one thing we redistribute). Apache
NOTICE contents are reproduced, not summarised; OpenRAIL Attachment A is
reproduced.

### D3. First-launch card flow

1. A component launcher (image build, container start, FIRST_RUN installer,
   model fetch) asks the tray: `licence_check <component> <version>`.
2. The tray reads the register row and the acceptance store.
   - `acknowledge`, not yet shown for this image: queue a non-blocking card
     (one per **image**, listing the components under it); write an
     unsigned `acknowledged` event; continue.
   - `accept`, no valid record: show the blocking Mācron card (lawyer, with
     briefcase) docked in the first-use window beside the download size bar
     where there is one; render the licence text; on Accept, the approval
     broker issues a nonce and asks the OS (Hello / Touch ID / FIDO2 /
     polkit fallback) to sign the statement; store; continue.
   - `accept`, record present and `licence_sha256` matches: continue silently.
   - `refuse`: the launcher is told no; nothing downloads.
3. The forge can only ask; it never sees the nonce and cannot accept for the
   user (same boundary as approvals).

### D4. The signed acceptance record

Statement (canonical lines, SSHSIG namespace `tillandsias-licence-acceptance@v1`):
`component, version, source, licence_id, licence_url, licence_sha256, tier,
installation (installation-uuid), host, user, strength, nonce, accepted`.
Stored append-only in the host acceptance journal beside the approval journal
and as `$XDG_STATE_HOME/tillandsias/licences/<component>/<version>.sshsig`;
verified by `ssh-keygen -Y verify -n tillandsias-licence-acceptance@v1`
against the host's allowed-signers file. Never in a project repo. The record
proves the user's assent on this device; the cheatsheet says what it does
not prove.

### D5. Card wording

Shown with the Mācron lawyer illustration. Plain, friendly, honest: the
acknowledge card must not imply acceptance is required.

**Acknowledge tier** (one card per image, dismissable, once):

- Option A1: "Heads up: {image} uses open-source software. It includes
  {component list}, under the {licence list} licences. You can use it freely;
  the authors just ask to be credited, and they are, under About > Licences.
  [Got it] [Show licences]"
- Option A2: "This part of Tillandsias is built on open-source work by other
  people. {n} components, licences: {MIT, Apache-2.0, ...}. Nothing to sign,
  nothing to agree to, just good to know who made it. [Got it] [See the list]"

**Accept tier** (blocking, signed):

- Option B1: "{Component} {version} is third-party software with its own
  licence: the {licence name}. It is not open source, and it has conditions
  on how you may use it. Please read it before continuing; Tillandsias will
  ask your {Windows Hello / Touch ID / security key} to sign your acceptance
  so you have a record. [Read the full licence] [I accept] [Not now]"
- Option B2 (model, OpenRAIL): "The {model} model is licensed under the
  CreativeML Open RAIL++-M licence. You may use and share it, but the licence
  lists uses that are not allowed (shown below). By continuing you agree to
  those terms. [Full licence text] [I accept these terms] [Don't download]"
- Option B3 (account-terms CLI): "{Claude Code} is Anthropic's software and
  runs under the Anthropic terms you agreed to when you created your account.
  Tillandsias doesn't license it; it installs it for you. [Read the terms]
  [Understood, continue] [Don't install]"

Sub-line under every accept card: "Your acceptance is signed by this
device's security hardware and kept only on this computer."

## Work packets

### Work Packet: 1940-ilic

- id: `1940-ilic`
- owner_host: linux
- capability_tags: [licensing, lua, inference, policy]
- status: ready
- priority: first (coordinator, 2026-10-31: the most urgent finding)
- discovered_by: operator direction 2026-10-31, research in this file (F6, F7)
- evidence:
  - `images/inference/tiers/*.tsv` — LLM pins with no licence column
  - `images/inference/decode-floor-pin.sh` — names `qwen2.5:3b` (Qwen Research licence, non-commercial-style) in comments
- next_action: >
    Add an `spdx` column to every inference tier table and a Lua checker
    (sibling of scripts/lua/check-model-licence-register.lua) that refuses a
    pin whose licence is not on the allowlist, with explicit refusals for
    `qwen2.5:3b` and `qwen2.5:72b`. Verify each pinned model's licence
    against its card and record the URL and date. Ships ahead of, and does
    not wait for, 1940-creg.

### Work Packet: 1940-creg

- id: `1940-creg`
- owner_host: linux
- capability_tags: [licensing, lua, register, images, policy]
- status: ready
- discovered_by: operator direction 2026-10-31, research in this file
- evidence:
  - `images/models/licence-register.tsv` — the shape to extend
  - `scripts/lua/check-model-licence-register.lua` — the checker to sibling
  - F4 inventory table above — the initial rows
- next_action: >
    Add `images/licence-register.tsv` with the F4 rows (mark `unverified`
    entries and verify each against its primary source, recording the URL and
    date), and `scripts/lua/check-component-licence-register.lua` that
    refuses an unregistered FROM/npm/pip/clone/tier-table reference, a
    referenced `refuse` row, and a `redistributed` row in the accept family.
    Wire it into `./build.sh --check`. Fold the inference tier tables' models
    (Qwen2.5 sizes, nomic-embed-text) into the register with their Apache-2.0
    ids, and add explicit `refuse` rows for `qwen2.5:3b` and `qwen2.5:72b`.

### Work Packet: 1940-ntcs

- id: `1940-ntcs`
- owner_host: linux
- capability_tags: [licensing, rust, policy, release]
- status: ready
- discovered_by: research in this file (D2)
- evidence:
  - `scripts/regenerate-cheatsheet-index.sh` — precedent for a
    `tillandsias-policy` subcommand that renders a tracked file from
    structured input
- next_action: >
    Add `tillandsias-policy generate-third-party-notices` rendering
    `THIRD-PARTY-NOTICES.md` from the register (verbatim Apache NOTICE
    contents, verbatim OpenRAIL Attachment A, licence text or link per row),
    a `--check` mode, and include the file in the release tarball and the
    tray's About page. Depends on `1940-creg`.

### Work Packet: 1940-stmt

- id: `1940-stmt`
- owner_host: linux
- capability_tags: [licensing, approval-broker, sshsig, rust, security]
- status: ready
- discovered_by: research in this file (D4), builds on os-verified-approval-gates
- evidence:
  - `openspec/changes/os-verified-approval-gates/design.md` D1-D4
  - `cheatsheets/legal/runtime-acknowledgement-vs-acceptance.md`
- next_action: >
    Write the OpenSpec delta adding the `tillandsias-licence-acceptance@v1`
    statement kind to the approval broker: canonical lines, nonce issuance,
    strength labelling per platform (fprintd-only Linux hosts record
    `software-password`), storage in the host acceptance journal and
    `$XDG_STATE_HOME/tillandsias/licences/`, and verification with
    `ssh-keygen -Y verify`. Blocked on the broker landing; the delta can land
    before it.

### Work Packet: 1940-card

- id: `1940-card`
- owner_host: linux
- capability_tags: [licensing, tray-ui, approval-dialog, macron, ux]
- status: ready
- discovered_by: operator direction 2026-10-31 (Mācron lawyer card)
- evidence:
  - `openspec/changes/os-verified-approval-gates/specs/approval-dialog/spec.md`
  - `openspec/changes/os-verified-approval-gates/specs/first-use-download-consent/spec.md`
  - D5 wording above
- next_action: >
    Spec and implement the two cards (acknowledge: one per image,
    non-blocking, unsigned; accept: blocking, docked in the first-use window,
    signed via the broker) using the D5 wording after the operator picks the
    options, the Mācron lawyer-with-briefcase illustration in the shared
    Mācron asset set, and a `licence_check` tray request used by image build,
    container start, FIRST_RUN installers and model fetch. The acknowledge
    card must never say acceptance is required.

### Work Packet: 1940-txtp

- id: `1940-txtp`
- owner_host: linux
- capability_tags: [licensing, provenance, cheatsheet-sources]
- status: ready
- discovered_by: research in this file (licence_sha256 column)
- evidence:
  - `cheatsheets/legal/*.md` Provenance sections — the URLs to pin
- next_action: >
    Fetch and commit verbatim copies of each accept-tier licence text
    (OpenRAIL++-M, BUSL-1.1 Vault v1.18.0 LICENSE, NVIDIA Deep Learning
    Container License, Cloudflare Application Terms snapshot, Anthropic
    Commercial Terms snapshot) under `cheatsheet-sources/` with `local:`
    lines in the cheatsheets, and record their sha256 in the register so the
    card renders the pinned text and refuses on drift.

### Work Packet: 1940-rdst

- id: `1940-rdst`
- owner_host: linux
- capability_tags: [licensing, release, gate, build-script]
- status: ready
- discovered_by: F1 (the boundary that matters)
- evidence:
  - `scripts/build-image.sh` — no push today
  - `build.rs` embeds `images/`
- next_action: >
    Add a gate that refuses any new `podman push`/registry publish script or
    any vendored binary/model under `images/` whose register row is
    `accept`-tier or `refuse`-tier, so a convenience change cannot silently
    turn "fetched" into "redistributed" for NVIDIA, WARP, Vault or an
    OpenRAIL model. Prints the cheatsheet path as the remedy.
