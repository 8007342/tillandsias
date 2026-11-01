---
tags: [licence, busl, business-source-license, hashicorp, vault, field-of-use, change-license, mpl]
languages: []
since: 2026-10-31
last_verified: 2026-10-31
sources:
  - https://raw.githubusercontent.com/hashicorp/vault/v1.18.0/LICENSE
  - https://mariadb.com/bsl11/
  - https://www.hashicorp.com/en/license-faq
  - https://www.hashicorp.com/en/blog/hashicorp-adopts-business-source-license
  - https://spdx.org/licenses/BUSL-1.1.html
  - https://www.mozilla.org/en-US/MPL/2.0/
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---
# BUSL-1.1 and HashiCorp Vault in the enclave

@trace spec:cheatsheet-tooling, spec:tillandsias-vault
@cheatsheet legal/combining-licences-without-conflict.md, runtime/hashicorp-vault-tillandsias.md

**This is not legal advice.** The quotes are from the Vault v1.18.0 LICENSE
file and the BUSL-1.1 template; HashiCorp's own FAQ is the interpretation we
follow where the text is open.

**Version baseline**: `docker.io/hashicorp/vault:1.18` (`images/vault/Containerfile`,
and the `vault` binary copied into `images/git/Containerfile`). Vault 1.15.0
and later are BUSL-1.1; earlier releases were MPL-2.0.
**Use when**: bumping the Vault image, wondering whether the enclave Vault
can ship in a published image, or wording its first-launch card.

## The licence, as pinned

From `hashicorp/vault` tag `v1.18.0`, file `LICENSE` (fetched 2026-10-31):

- Licensor: HashiCorp, Inc.
- Licensed Work: Vault Version 1.15.0 or later.
- Additional Use Grant: "You may make production use of the Licensed Work,
  provided Your use does not include offering the Licensed Work to third
  parties on a hosted or embedded basis in order to compete with HashiCorp's
  paid version(s) of the Licensed Work."
- Change Date: four years from the date the Licensed Work is published.
- Change License: MPL 2.0.

BUSL-1.1 body (template at mariadb.com/bsl11): non-production use is always
permitted; production use only under the Additional Use Grant; "You must
conspicuously display this License on each original or modified copy of the
Licensed Work"; on the Change Date the work becomes available under the
Change License. SPDX id `BUSL-1.1`. Not OSI-approved.

## Does Tillandsias' use fit the grant?

| Question | Reading |
| --- | --- |
| Is running Vault as the enclave's secrets backend "production use"? | Yes, treat it as production; the non-production carve-out is for dev/test. |
| Is it "offering the Licensed Work to third parties on a hosted or embedded basis in order to compete with HashiCorp's paid versions"? | Vault serves only the local enclave (hostname `vault`, port 8200, nothing exposed beyond the enclave per the runtime cheatsheet). It is not offered to third parties and does not compete with HCP Vault. HashiCorp's FAQ says embedding is fine unless the product is competitive with their commercial offering. **Fits the grant on today's facts.** |
| What changes the answer? | Exposing the enclave Vault to other users as a service, or marketing Tillandsias as a secrets-management product. Re-read this sheet before either. |
| Do we redistribute Vault? | No: `images/vault` and `images/git` are built locally from the upstream image; nothing is pushed. If an image is ever published, the conspicuous-display clause attaches (ship the LICENSE file at a visible path and name it in the image labels). |

## Obligations checklist

- Fetch (today): none from the licence text itself beyond staying inside the
  grant. The user is the licensee of their locally pulled copy.
- Runtime card: `accept` tier, because the licence is a **use** restriction
  the user is bound by, and because BUSL is unfamiliar enough that "it's open
  source" would be a false impression. The card states the grant in one
  sentence and links the LICENSE at the pinned tag.
- Redistribute (if ever): LICENSE conspicuously displayed; keep HashiCorp's
  copyright; no additional terms that contradict the grant.
- Change Date tracking: each Vault minor has its own publication date; the
  register row should carry the tag's release date so the Change Date (date +
  4 years, when that version becomes MPL-2.0) is computable. Do not assume a
  single date for "Vault".

## Alternatives, for the record

OpenBao (Linux Foundation fork of Vault 1.14, MPL-2.0) exists if a
permissive-only enclave is ever required. Not researched beyond its licence;
a swap is a spec change, not a licence note.

## Common pitfalls

- Calling Vault "open source" in docs or in the card. It is source-available.
- Copying the MPL-2.0 text from an old Vault into a notice file: the pinned
  1.18 text is BUSL-1.1.
- Reading the Change License as if it applied today: it applies per version,
  four years after that version's publication.
- Assuming the Additional Use Grant text is the same across HashiCorp
  products: each product's LICENSE file carries its own grant wording.

## Provenance

- <https://raw.githubusercontent.com/hashicorp/vault/v1.18.0/LICENSE> — fetched 2026-10-31, lines quoted above
- <https://mariadb.com/bsl11/> — BUSL-1.1 template; conspicuous-display sentence quoted (fetched 2026-10-31)
- <https://www.hashicorp.com/en/license-faq> — HashiCorp's reading of "embedded" and "compete"
- <https://www.hashicorp.com/en/blog/hashicorp-adopts-business-source-license> — the 2023 relicensing announcement (1.15 boundary)
- <https://spdx.org/licenses/BUSL-1.1.html> — identifier
- <https://www.mozilla.org/en-US/MPL/2.0/> — the Change License
- Derived (not provenance): `images/vault/Containerfile:16`, `images/git/Containerfile:19,64` read 2026-10-31.

## See also

- `legal/combining-licences-without-conflict.md`
- `legal/runtime-acknowledgement-vs-acceptance.md`
- `runtime/hashicorp-vault-tillandsias.md`
