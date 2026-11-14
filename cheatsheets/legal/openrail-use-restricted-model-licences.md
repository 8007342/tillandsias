---
tags: [licence, openrail, creativeml, model-licence, use-restrictions, stable-diffusion, huggingface, attachment-a]
languages: []
since: 2026-10-31
last_verified: 2026-10-31
sources:
  - https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/raw/main/LICENSE.md
  - https://huggingface.co/spaces/CompVis/stable-diffusion-license
  - https://www.licenses.ai/blog/2022/8/18/naming-convention-of-responsible-ai-licenses
  - https://huggingface.co/docs/hub/repositories-licenses
  - https://huggingface.co/docs/hub/models-gated
  - https://huggingface.co/ByteDance/SDXL-Lightning
  - https://huggingface.co/IDKiro/sdxs-512-0.9
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---
# OpenRAIL and other use-restricted model licences

@trace spec:cheatsheet-tooling
@cheatsheet legal/combining-licences-without-conflict.md, legal/runtime-acknowledgement-vs-acceptance.md

**This is not legal advice.** Quotes are from the licence texts under
Provenance; apply them with a lawyer when money or a published product is
involved.

**Version baseline**: CreativeML Open RAIL++-M (Stability AI, 26 July 2023),
as carried by `ByteDance/SDXL-Lightning` and `IDKiro/sdxs-512-0.9`, both in
`images/models/licence-register.tsv` with spdx `openrail++`.
**Use when**: adding a model row to the register, wording the first-launch
card for a model, or deciding whether a model can be bundled or offered.

## What RAIL licences are

"Responsible AI Licenses" (RAIL) are permissive-looking licences with an
attached list of **use restrictions**. `Open` means the weights may be freely
redistributed and modified; `M` means the restrictions cover the model; `++`
is Stability's 2023 revision of the original CreativeML Open RAIL-M (2022,
SD 1.x/2.x). Neither is OSI-approved and neither is in the SPDX list as a
licence id; Hugging Face uses the tag strings `openrail`, `openrail++`,
`creativeml-openrail-m`. The register stores those tags, which is why it is
not an SPDX column strictly speaking.

## The clauses that matter to Tillandsias

| Clause (OpenRAIL++-M) | Effect |
| --- | --- |
| Section II.3 grant | royalty-free, worldwide, to use, reproduce, distribute, make derivatives of the Model |
| Section III.4 (distribution) | a copy of the licence and all notices must travel with any redistribution of the Model or Derivatives |
| Section III.5 (use-based restrictions) | "Use-based restrictions as referenced in paragraph 5 MUST be included as an enforceable provision by You in any type of legal agreement (e.g. a license) governing the use and/or distribution of the Model or Derivatives of the Model, and You shall give notice to subsequent users You Distribute to that the Model or Derivatives of the Model are subject to paragraph 5." |
| Section III.6 (output) | the licensor claims no rights over generated output; you are accountable for it |
| Section IV (trademarks), V (warranty), VI (liability) | standard disclaimers |
| Attachment A | the eleven prohibited uses, reproduced below |

### Attachment A, verbatim (OpenRAIL++-M)

You agree not to use the Model or Derivatives of the Model:

1. In any way that violates any applicable national, federal, state, local or international law or regulation;
2. For the purpose of exploiting, harming or attempting to exploit or harm minors in any way;
3. To generate or disseminate verifiably false information and/or content with the purpose of harming others;
4. To generate or disseminate personal identifiable information that can be used to harm an individual;
5. To defame, disparage or otherwise harass others;
6. For fully automated decision making that adversely impacts an individual's legal rights or otherwise creates or modifies a binding, enforceable obligation;
7. For any use intended to or which has the effect of discriminating against or harming individuals or groups based on online or offline social behavior or known or predicted personal or personality characteristics;
8. To exploit any of the vulnerabilities of a specific group of persons based on their age, social, physical or mental characteristics, in order to materially distort the behavior of a person pertaining to that group in a manner that causes or is likely to cause that person or another person physical or psychological harm;
9. For any use intended to or which has the effect of discriminating against individuals or groups based on legally protected characteristics or categories;
10. To provide medical advice and medical results interpretation;
11. To generate or disseminate information for the purpose to be used for administration of justice, law enforcement, immigration or asylum processes, such as predicting an individual will commit fraud/crime commitment (e.g. by text profiling, drawing causal relationships between assertions made in documents, indiscriminate and arbitrarily-targeted use).

## What this means for the two flows

- **Fetch (today)**: the user's machine downloads the weights from the Hub.
  The Hub shows the card; the model is ungated (register `gated=false`).
  Section III.5 is written for *distributors*, and we do not distribute the
  weights. But Tillandsias is the thing that **runs** the model for the user
  and the Attachment A restrictions bind **the user**. Showing Attachment A
  and recording the user's acceptance before first inference is the honest
  reading of "give notice to subsequent users" and the only way the user can
  know the terms they are bound by.
- **Redistribute (if a model is ever baked into a release or a pushed image)**:
  III.4 and III.5 apply in full: licence text travels, Attachment A must be an
  **enforceable provision** of whatever terms we put on that artefact. That
  means our own terms would have to incorporate Attachment A by reference.
  Avoid by not bundling.

## Tier decision

`accept`, not `acknowledge`: the licence imposes affirmative obligations on
the user that they cannot learn from a permissive-style attribution line.
The card must reproduce Attachment A (scrollable), link the full text, and
record the licence text sha256 (the register already pins the file sha256;
the text hash is a separate column proposed in the plan issue).

## Refused neighbours (register header, verified 2026-10-28)

Non-commercial or revenue-capped model licences are **refused** rather than
tiered: FLUX.1-dev (non-commercial, gated), SD3/SD3.5 (Stability Community,
revenue cap, gated), SDXL-Turbo and SD-Turbo (non-commercial), BRIA RMBG
(custom non-commercial), Qwen research/MAU-capped variants, Gemma terms.
`FLUX.1-schnell` is Apache-2.0 and in. A field-of-use or non-commercial term
is a `refuse` tier in the proposed component register, not an `accept`.

## Common pitfalls

- The Hub licence tag is self-declared by the uploader. Read the LICENSE file
  in the repo at the pinned revision; the register's `card` column records
  where the id was read.
- A GGUF re-quantisation inherits the original weights' licence; the
  re-uploader cannot relicense (`second-state/FLUX.1-schnell-GGUF` is
  Apache-2.0 only because FLUX.1-schnell is).
- OpenRAIL-M (2022) and OpenRAIL++-M (2023) differ in Attachment A wording;
  pin the text hash per model, do not share one hash across the family.
- The output clause (III.6) does not make outputs unrestricted; Attachment A
  is about **use**, and generating prohibited content is a prohibited use.

## Provenance

- <https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/raw/main/LICENSE.md> — OpenRAIL++-M full text (fetched 2026-10-31; III.5 and Attachment A quoted verbatim above)
- <https://huggingface.co/spaces/CompVis/stable-diffusion-license> — original CreativeML Open RAIL-M (2022)
- <https://www.licenses.ai/blog/2022/8/18/naming-convention-of-responsible-ai-licenses> — RAIL naming (Open, M, D, S)
- <https://huggingface.co/docs/hub/repositories-licenses> — the Hub's licence tag vocabulary (`openrail`, `openrail++`, `creativeml-openrail-m`)
- <https://huggingface.co/docs/hub/models-gated> — gating semantics the register's `gated` column relies on
- <https://huggingface.co/ByteDance/SDXL-Lightning>, <https://huggingface.co/IDKiro/sdxs-512-0.9> — the two openrail++ cards in the register
- Derived (not provenance): `images/models/licence-register.tsv` header and rows, read 2026-10-31.

## See also

- `legal/combining-licences-without-conflict.md`
- `legal/runtime-acknowledgement-vs-acceptance.md`
- `images/models/licence-register.tsv`, `scripts/lua/check-model-licence-register.lua`
