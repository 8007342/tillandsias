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

## Status: NOT AVAILABLE ON THIS HOST YET

The approval tool (`licence.acknowledge`; orders 2022-ygqj, 2022-89hm,
2022-hn2k) has not shipped. Until it lists in `tools/list` on this host:

- Do NOT walk the user through commands, heredocs, `--approval-enrol`,
  `--approval-sign`, `ssh-keygen`, or copying text off a screen. The user
  must never move bytes by hand (operator ruling 2026-11-14: "I cannot copy
  that text from the screen into the clipboard. This is the stupidest
  interaction in the world ever.").
- NEVER write, paste or accept an allowed-signers line, a public key or a
  signature that did not come from the host's own enrol/sign path. The trust
  anchor of this gate must be written by the host, never delivered by a paste
  or a chat message (incident 2026-11-14, order 2083-nfne). This skill never
  instructs a manual or terminal flow, now or after the tool ships.
- Say, in plain words: "Accepting licences from here is not available on
  this machine yet; it is coming." Name the refused artefact, stop, and do
  not write a record.
- You may still do step 1 (read the row, check the licence hash) to tell the
  user what is blocked.

## 2. Target flow once the tool ships (the only flow)

The user says something vague, for example "yo lets accept depry and herpy
licenses, duh". The user is never asked for ids, slugs, scope, use or expiry.

1. Resolve. You map the fuzzy names to register rows yourself (fuzzy and
   semantic match, plus the project's pending
   `licence_acknowledgement_required` refusals) and propose defaults from
   policy: non-sale, one year; `standing` only where the policy allows.
2. ONE call to the tool for the whole batch, however many licences. The tray
   shows ONE native window listing every acknowledgeable: each licence's
   verbatim clauses, the artefacts, and the scope and use in plain words. The
   approve control stays disabled until the user has scrolled to the bottom.
   Touch ID, Windows Hello or polkit signs all of them and the window closes.
   Cancel signs nothing. You build no statement text; the tray builds it
   (`licence_consent::Acknowledgement::statement_text`).
3. The tray enrols the per-repo key silently if needed and returns the signed
   records in the MCP result. Nothing is printed for anyone to copy.
4. Continue below with the returned records.

Acceptance bar: a non-technical user. The transcript shows exactly one user
utterance and one biometric touch.

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
