---
tags: [licence, license, spdx, notice, attribution, compatibility, gpl, apache, mit, bsd, mpl, redistribution]
languages: []
since: 2026-10-31
last_verified: 2026-10-31
sources:
  - https://spdx.org/licenses/
  - https://opensource.org/licenses
  - https://www.gnu.org/licenses/license-list.html
  - https://www.gnu.org/licenses/gpl-faq.html
  - https://www.apache.org/licenses/LICENSE-2.0
  - https://www.apache.org/legal/resolved.html
  - https://www.apache.org/licenses/GPL-compatibility.html
  - https://www.mozilla.org/en-US/MPL/2.0/
  - https://www.mozilla.org/en-US/MPL/2.0/FAQ/
  - https://opensource.org/license/mit
  - https://opensource.org/license/bsd-3-clause
  - https://www.gnu.org/licenses/gpl-3.0.html
  - https://www.gnu.org/licenses/lgpl-3.0.html
  - https://mariadb.com/bsl11/
  - https://docs.fedoraproject.org/en-US/legal/license-approval/
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---
# Combining third-party licences without conflict

@trace spec:cheatsheet-tooling
@cheatsheet legal/runtime-acknowledgement-vs-acceptance.md, legal/openrail-use-restricted-model-licences.md, legal/busl-1-1-hashicorp-vault.md, legal/proprietary-eulas-in-the-stack.md

**This is not legal advice.** It is an engineering cheatsheet distilled from the
licence texts and the publishers' own FAQs cited under Provenance. When a real
decision depends on it (a published image, a commercial offering, an
acquisition), ask a lawyer and hand them this sheet as the starting inventory.

**Version baseline**: the component inventory in
`plan/issues/third-party-licence-management-2026-10-31.md`
**Use when**: adding a container image, a vendored web component, an npm/pip
package, a model, or a CLI agent to Tillandsias, and you need to know what
notice to carry, whether the combination is allowed, and whether the user has
to see anything at runtime.

## The one distinction that decides almost everything

Every obligation in every licence below is triggered by **distribution**
(conveying a copy to someone else), not by **use**. Tillandsias today:

| Flow | What leaves our hands | Who distributes the third-party bits |
| --- | --- | --- |
| Tray binary (GitHub release) | our Rust code + embedded `images/` tree (Containerfiles, scripts, cheatsheets, vendored assets baked by `build.rs`) | **we do**, for anything inside the binary |
| Container images | built **locally** by `scripts/build-image.sh`; no `podman push`, no registry publish found in `scripts/` or `.github/` | the user's own podman pulls `FROM` bases and packages from upstream; **upstream distributes to the user** |
| Runtime self-installs | ollama tarball (`images/inference/entrypoint.sh`), npm CLIs (`lib-common.sh` `_require_harness`), cargo tools, Dart SDK, HF model files | **upstream distributes to the user**; we are the installer |
| Vendored at image build | GrapesJS (`images/web-studio-grapesjs/`, PR #755) | fetched on the user's machine into a local image; still "upstream to user" unless the image is pushed |

So the operator's "we're technically not redistributing ourselves" is **true
for the images and runtime fetches and false for whatever rides inside the
release binary**. Keep that boundary explicit: the moment an image is pushed
to a registry or a model is bundled into the release, the distribution
obligations below attach to Tillandsias.

Two things do not depend on distribution and therefore apply **always**:

- **Use restrictions** (OpenRAIL Attachment A, BUSL Additional Use Grant,
  NVIDIA container EULA 4.g/4.h). These bind the user, so the user must be
  told. This is the real reason for a runtime prompt.
- **Click-through EULAs** that say "by installing you agree" (Cloudflare WARP,
  NVIDIA containers). The user is the party agreeing, not us.

## Family-by-family obligations

"Redistribute" = we ship it (release binary, pushed image). "Fetch" = the
user's machine pulls it from upstream at build or run time.

| Family (SPDX) | Redistribute: must do | Fetch: must do | Use restriction | Copyleft | Runtime tier (see acknowledgement sheet) |
| --- | --- | --- | --- | --- | --- |
| MIT | keep copyright + permission notice with the copy | nothing | none | none | acknowledge |
| BSD-3-Clause | keep notice in source and in binary docs/materials; no endorsement with contributor names | nothing | none | none | acknowledge |
| Apache-2.0 | keep LICENSE, keep NOTICE contents if upstream ships one (section 4(d)), mark modified files; patent grant with retaliation | nothing | none | none | acknowledge |
| MPL-2.0 | file-level copyleft: source of **modified MPL files** must be offered; larger work may be any licence (section 3.3); notices kept | nothing | none | file-level | acknowledge |
| LGPL-2.1 / LGPL-3.0 | source offer for the library and the ability to relink; the application may stay proprietary if it only links | nothing | none | library-level | acknowledge |
| GPL-2.0 / GPL-3.0 | full corresponding source for the work and anything that is "one program" with it; running it as a separate process (squid, ComfyUI, fedora tools) does not pull our code in (GPL FAQ "MereAggregation", "GPLPlugins") | nothing | none | strong | acknowledge |
| BUSL-1.1 | conspicuously display the licence on each copy; non-production use free; production use only within the **Additional Use Grant** | nothing, but the grant still limits **use** | field-of-use (no competing hosted/embedded offering) | none (converts to Change License after 4 years) | accept |
| CreativeML OpenRAIL-M / OpenRAIL++-M | keep the licence; **pass Attachment A to every downstream user as an enforceable term** (section III.5) | the Hub shows the user the card; we must still surface Attachment A because **we** are the one making the model run | Attachment A (11 items) | none | accept |
| Proprietary EULA (NVIDIA container, Cloudflare WARP, Claude Code terms) | usually **not permitted** to redistribute at all (NVIDIA 4.c; WARP "licensed, not sold") | the user accepts by installing (both texts say so) | yes, see EULA sheet | n/a | accept (and never bundle) |

Attribution formats that satisfy MIT/BSD/Apache in one place: a
`THIRD-PARTY-NOTICES` file (or an "About > Licences" page) listing, per
component, the name, version, SPDX id, copyright line and the verbatim
licence text or a pointer to it. Apache's own guidance
(`apache.org/legal/resolved.html`) accepts a single aggregated NOTICE, as long
as each upstream NOTICE's content is reproduced, not summarised.

## Compatibility matrix for the families we actually mix

Read as "can code under ROW be combined into one program with code under
COLUMN and the result shipped?" Combination here means linking or deriving;
running side by side as separate processes is **mere aggregation** and always
fine (GPL FAQ "MereAggregation").

| ↓ into → | MIT / BSD-3 | Apache-2.0 | MPL-2.0 | LGPL | GPL-2.0 | GPL-3.0 | BUSL-1.1 | OpenRAIL |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| MIT / BSD-3 | yes | yes | yes | yes | yes | yes | yes (notice) | yes |
| Apache-2.0 | yes | yes | yes | yes (v3; LGPLv2.1 same problem as GPLv2) | **no** per FSF (patent-termination and indemnity terms exceed GPLv2) | yes | yes (notice) | yes |
| MPL-2.0 | yes (MPL files stay MPL) | yes | yes | yes via section 1.12 secondary licences | yes via secondary licences, unless upstream marked "Incompatible With Secondary Licenses" | same | yes, MPL files stay MPL | yes |
| GPL-3.0 code | the whole work becomes GPL-3.0 | same | same | same | **no** (GPLv2-only is incompatible with v3) | yes | **no**: BUSL is not GPL-compatible, and section 4.g-style clauses do not exist in BUSL but the Additional Use Grant is an added restriction | n/a |
| BUSL-1.1 | n/a (we do not derive from Vault) | n/a | n/a | n/a | no | no | yes | n/a |
| OpenRAIL weights | a model is data to the code; Attachment A travels with the weights, not with the program | same | same | same | same | same | same | yes |

Notes behind the cells:

- **Apache-2.0 vs GPLv2**: FSF lists Apache-2.0 as compatible with GPLv3 only;
  the ASF agrees (`apache.org/licenses/GPL-compatibility.html`). Only matters
  if we ever link Apache code into a GPLv2-only work. We do not today.
- **MPL-2.0**: dual-natured. Files stay MPL, the surrounding work can be
  anything; GPL combination works through section 3.3 and the definition of
  "Secondary License" in 1.12.
- **GPL in our stack** (squid, ComfyUI, fedora/debian/alpine packages) is
  consumed as **separate processes** inside containers. Nothing of ours links
  to it. No copyleft obligation flows to the tray.
- **BUSL** is neither OSI-approved nor FSF-free. It is not a copyleft and
  does not infect; it limits **use**. We run Vault as a separate service
  (fetch, not redistribute).
- **OpenRAIL** is not OSI-approved either (use restrictions). Weights are
  not "linked"; the restriction travels to **the user of the model**.

## How to reference several licences in one product

1. **One SPDX expression per component, never per product.** A product has
   an inventory, not a licence. Tillandsias' own code keeps its own licence;
   third-party components are listed with their SPDX ids
   (`https://spdx.org/licenses/`). Use `AND` only for a single artefact that is
   genuinely under two licences at once; use `OR` for a dual-licence choice
   (e.g. wrangler `MIT OR Apache-2.0`) and record which arm we chose.
2. **One register, machine-read.** The media model register
   (`images/models/licence-register.tsv`) is the shape: one row per fetched
   artefact, pinned revision, licence id, text hash, where the id was read.
   The component register proposed in the plan issue extends it to images,
   npm/pip packages and CLIs, and adds `distribution` (`redistributed` |
   `fetched`) and `tier` (`acknowledge` | `accept` | `refuse`).
3. **One aggregated notice file, generated from the register**, shipped in
   the release binary and shown under About. Per entry: name, version, SPDX
   id, copyright holder, licence text (verbatim for MIT/BSD, by reference
   plus NOTICE contents for Apache), and for use-restricted licences the
   restriction text itself (OpenRAIL Attachment A must be reproduced, not
   summarised).
4. **Never merge licence texts.** A "combined licence" is not a thing; each
   component is licensed under its own text. The product's documentation says
   "this product contains components under the following licences" and lists
   them.
5. **Keep the user-facing surface for use restrictions separate from the
   attribution list**, so the two tiers stay honest: the attribution list is
   informational; the acceptance card is contractual for the user.

## Common pitfalls

- Treating "we build the image locally" as "no obligations": correct for
  distribution, wrong for use restrictions and EULAs.
- Baking a model or a BUSL/EULA binary into the release tarball "for
  convenience": that converts fetch into redistribute and, for NVIDIA and
  WARP, is prohibited outright.
- Copying an Apache NOTICE into a summary: 4(d) wants the **contents**.
- Reading the model card's licence badge as the licence: the register reads
  the card URL and pins the text hash for a reason; cards drift.
- Mistaking an acknowledge card for a contract: permissive licences grant
  rights without any acceptance. Do not word the card as if clicking were
  required (see the acknowledgement sheet).
- A Fedora package's `License:` tag is an SPDX expression since Fedora 38
  (docs.fedoraproject.org legal); `rpm -q --qf '%{LICENSE}'` is the source of
  truth for distro bits, not the upstream README.

## Provenance

- <https://spdx.org/licenses/> — identifier list used for every id above
- <https://opensource.org/licenses> — OSI approval status (BUSL and OpenRAIL are absent)
- <https://www.gnu.org/licenses/license-list.html> — FSF compatibility verdicts (Apache-2.0: GPLv3 only; MPL-2.0: compatible via secondary licences; Expat and modified BSD: compatible). Fetched 2026-10-31 returned HTTP 429; verdicts quoted from the list as last read, re-verify on next bump.
- <https://www.gnu.org/licenses/gpl-faq.html> — "MereAggregation", "GPLPlugins", "LinkingWithGPL"
- <https://www.apache.org/licenses/LICENSE-2.0> — section 4 (redistribution, NOTICE)
- <https://www.apache.org/legal/resolved.html> — category A/B/X and NOTICE aggregation practice
- <https://www.apache.org/licenses/GPL-compatibility.html> — ASF statement on GPLv2 incompatibility
- <https://www.mozilla.org/en-US/MPL/2.0/> — sections 1.12, 3.3; <https://www.mozilla.org/en-US/MPL/2.0/FAQ/> Q8-Q13
- <https://opensource.org/license/mit>, <https://opensource.org/license/bsd-3-clause>
- <https://www.gnu.org/licenses/gpl-3.0.html>, <https://www.gnu.org/licenses/lgpl-3.0.html>
- <https://mariadb.com/bsl11/> — BUSL-1.1 text: "You must conspicuously display this License on each original or modified copy of the Licensed Work." (fetched 2026-10-31)
- <https://docs.fedoraproject.org/en-US/legal/license-approval/> — Fedora licence tags are SPDX expressions
- Derived (not provenance): the distribution-vs-fetch table is read from this repository's `scripts/build-image.sh`, `images/*/Containerfile*`, `images/default/lib-common.sh` and `images/inference/entrypoint.sh` on 2026-10-31.

## See also

- `legal/runtime-acknowledgement-vs-acceptance.md`
- `legal/openrail-use-restricted-model-licences.md`
- `legal/busl-1-1-hashicorp-vault.md`
- `legal/proprietary-eulas-in-the-stack.md`
- `cheatsheets/license-allowlist.toml` (cheatsheet sources, a different register)
- `images/models/licence-register.tsv` (model files)
