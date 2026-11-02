---
name: accept-licence
description: Accept a third-party licence for a model or tool whose terms are outside the permissive list (non-commercial, share-alike, seat thresholds, OpenRAIL use restrictions, CorridorKey). Shows the licence verbatim through the tray, takes the OS-verified signed approval (Windows Hello, Touch ID, fingerprint, FIDO) through the approval gates, and commits the acknowledgement record plus an obligations spec into the agreeing project in one signed commit. Use when a fetch is refused with licence_acknowledgement_required, or when a project adds a restricted artefact. Works for any project in a Tillandsias forge.
license: MIT
metadata:
  author: tillandsias
  trace: order:1956-ecpb, order:1954-dvz9, spec:third-party-licence-consent
---

# Accept a licence

Tillandsias records consent; it does not enforce the licence and it does not
restrict the user. In the operator's words: "users should durably record
their consent to the third party license", and the skill "parses the license
and turns it into a spec for the agreeing project". Every step below serves
one of those two sentences. If you cannot complete a step, stop and say
which, instead of writing a record the gate cannot verify.

## When this runs

- A studio or imagegen request was refused with
  `licence_acknowledgement_required: <repo>/<file> licence <id> (<obligations>)`.
- A project is adding an artefact whose row lives in
  `images/models/licence-register-restricted.tsv` (the restricted register,
  studio-asset-pipeline design D6) rather than in the permissive register.

A refusal of `licence_forbids_use` (research-only terms) or `model_refused:
... is gated` is not for this skill: nobody clicks through gated terms or
research-only terms on a user's behalf. Say so and stop.

## 1. Read the row and the licence

```bash
grep -P "^[^#]" images/models/licence-register-restricted.tsv | grep -F "<repo>"
```

The row carries the artefact (repo, revision, file, sha256), the licence id,
the obligation classes and the sha256 of the licence text. Fetch the licence
text the card points at and check its hash equals `licence_sha256`. If the
row's hash is `pending:<url>`, the text was never pinned: pin it first (hash
it, replace the cell, commit that to Tillandsias) or stop. A record against
an unpinned text is worthless.

The obligation classes and their verbatim clauses come from
`crates/tillandsias-headless/src/licence_consent.rs::obligations_for`. For a
licence not in that table the only class is `review`: the owner reads the
text and classifies it before the record is written.

## 2. Show the licence verbatim through the tray

Ask the tray, never a paraphrase in chat. Through the host MCP:

```
browser.open <card URL>            # the licence as the publisher shows it
```

and in the approval dialog's detail, byte for byte from the register and
the licence text:

- licence id, version and `licence_sha256`;
- each restriction clause quoted verbatim (the `obligations_for` clauses);
- the artefact: repo, revision, file, sha256.

The user reads the quotes before anything is signed. The dialog carries no
sizes and no download times.

## 3. Take the OS-verified signed approval

The approval is an SSHSIG by the host's enrolled approval key, released only
after the OS check (os-verified-approval-gates D1 to D3): Touch ID on macOS,
Windows Hello on Windows, a FIDO2 key or the polkit-released software key on
Linux. The statement that is signed is canonical, built by
`licence_consent::Acknowledgement::statement_text`:

```
tillandsias-licence-acknowledgement v1
licence: <id>
licence_sha256: <64 hex>
covers: <repo>[, <repo>...]
grantor: <allowed-signers principal, e.g. operator>
scope: project:<name> | operator-projects
use: non-sale | commercial
expiry: standing | <RFC 3339>
host: <hostname>
strength: hardware-biometric | hardware-pin | hardware-presence | software-password
issued: <RFC 3339>
```

Ask the user for `scope`, `use` and `expiry` in those words. `standing` is
offered only from the tray's grant list, never as a reflex click in the
dialog (approval-gates R1). Namespace: `tillandsias-approval@v1`, the one
namespace every Tillandsias approval uses. The signer writes the statement
file and its `.sig`; on a Linux host with an enrolled key that is

```bash
ssh-keygen -Y sign -n tillandsias-approval@v1 -f <approval key> <statement file>
```

Verify before writing anything:

```bash
ssh-keygen -Y verify -n tillandsias-approval@v1 -I <grantor> \
  -f "${TILLANDSIAS_APPROVAL_ALLOWED_SIGNERS:-$XDG_STATE_HOME/tillandsias/approvals/allowed_signers}" \
  -s <statement file>.sig < <statement file>
```

A statement that does not verify is not recorded. Do not fall back to a
typed "yes": the record's value is the signature.

## 4. Write the record and the spec into the agreeing project

Two files, one commit, in the project's checkout (not in Tillandsias):

1. `licences/acknowledgements/<slug>.yaml`, in the format
   `Acknowledgement::to_yaml` writes (flat keys; `statement: |` and
   `signature: |` block scalars; `expiry` and `signed_at` double-quoted so no
   YAML reader turns them into dates). One record per licence TEXT: a record
   binds one `licence_sha256`. `<slug>` is the artefact repo slugified
   (`nikopueringer-corridorkey2-0`), or `<grantor>-<scope>-<expiry>` for a
   record covering several repos under one licence. The templates are the
   four seeds in `licences/acknowledgements/` of the Tillandsias checkout.
   Also drop a copy of the record where the host's gate reads it for a bare
   project label, `<state dir>/licence-acknowledgements/<project slug>/`
   (or `$TILLANDSIAS_LICENCE_ACK_DIR`): `admits_restricted(project, ...)` has
   no checkout handle, only the project's name.
2. `openspec/specs/third-party-licence-<id>/spec.md`, generated by
   `licence_consent::obligations_spec`: "This project depends on <artefact>
   and must now adhere to <obligations>", one `### Requirement:` per
   obligation with its verbatim clause and a `#### Scenario:`, each with a
   "How this project honours it" line. Ask the owner to fill those lines now
   ("the credits screen shows 'CorridorKey'"); a placeholder is acceptable
   for a first commit, a missing requirement is not.

Commit both with a signed commit (`git commit -S`; the project's signing key,
not the approval key) and the trailer
`Licence-Acknowledgement: <licence id> <licence_sha256>`. Push through the
project's own branch discipline (`/project-discipline`).

## 5. Confirm the gate

Re-run the refused request. The gate (`register_admits_with_consent`) admits
the row when the project's `licences/acknowledgements/` holds a record that
covers the repo, names the same licence id and licence hash, matches the
requester's scope, is in force, and whose signature verifies against the
host's enrolled signers. Tell the user what was admitted and which record
admitted it. The weights are fetched to that user's cache only; they are
never bundled in an image or a release.

## Acknowledgement #1

The operator's standing approval (2026-11-01, "For our own projects we shall
have a standing approval to use all of those free models, we'll not be
selling any of those assets") is seeded as four records in
`licences/acknowledgements/`, one per licence text of the CorridorKey 2.0 set
(`corridor-key-licence-2.0`, `nvidia-open-model-license`, `mit`,
`cc-by-4.0`): scope `operator-projects`, use `non-sale`, expiry `standing`.
They are unsigned until the operator signs them through this skill on a host
with an enrolled key; the NVIDIA one also waits for its licence text to be
pinned (the PDF was unreachable from the forge). The grant does not
authorise redistribution, or clicking through gated terms.
