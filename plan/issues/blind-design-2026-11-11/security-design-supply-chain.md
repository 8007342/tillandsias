# Supply chain — images, models, docs, and licence acceptance

Blind design from the promise. Invariants I10 and I11 are defined in
`credential-design.md` §2. Citations are from the author's knowledge; not
re-fetched this session.

## 1. Principle

Everything an agent runs *in*, runs *on*, or *reads as guidance* decides what
the agent does. So three artefact classes get the same bar:

| Class | Why it is "code" |
|-------|------------------|
| Container images (forge, relays, inference) | Literally code; relay images sit next to credentials |
| Model weights | Decide agent behaviour; some formats execute code on load; chat templates are programs |
| Docs / cheatsheets / skills / agent instruction files | Read by the agent as instructions — a poisoned cheatsheet is a prompt injection with a trusted letterhead [S1] |

The bar: **identified by digest, signed by a known identity, accompanied by
provenance that says how it was built from what, verified on the operator's
machine before first use, fail closed** (I10).

## 2. One manifest, one root of trust

Each tray release embeds (and is itself covered by) a **release manifest**:

```
release: vX.Y.Z
images:   [{name, digest, signer_identity, provenance_digest, sbom_digest}]
models:   [{name, revision, files:[{path, sha256, size}], format, licence_id,
            licence_class, signer_identity|null, source_url}]
docs:     [{bundle, digest, signer_identity}]
policy:   {permissive_licences:[SPDX ids], trusted_signers:[...]}
```

The manifest is signed. The tray binary carries the trust root needed to check
it. Update metadata follows TUF's separation of roles (root / targets /
snapshot / timestamp) so that a stolen release-signing key or a replayed old
manifest does not silently win: rollback and freeze attacks are what TUF is
for [S2]. Tray binaries are additionally OS-signed (Apple notarization,
Authenticode) because that is what the OS checks at launch; that signature is
*not* the product's trust root.

Tags are never trusted. Every pull is `name@sha256:…` taken from the manifest.

## 3. Images

**Build.** Images are built in a hosted CI from a tagged commit, on an
isolated, ephemeral builder, with no long-lived signing key: Sigstore keyless
signing binds the signature to the CI workflow's OIDC identity through Fulcio
and records it in the Rekor transparency log [S3]. The build emits:

- SLSA v1.0 provenance (in-toto statement, `predicateType`
  `https://slsa.dev/provenance/v1`) naming the source repo, commit, workflow
  and builder — target SLSA Build Level 3 [S4][S5];
- an SBOM (SPDX or CycloneDX) as a second attestation [S6];
- a secret-scan attestation over all layers (supports I1).

GitHub artifact attestations provide this shape for Actions builds and can be
verified with `gh attestation verify` or cosign [S7].

**Verify on the operator's machine.** Two layers, both required:

1. *Engine-level*: the product's podman store uses a `policy.json` whose
   default is `reject` and which allows only the product's registries with
   `sigstoreSigned` requirements pinned to the expected Fulcio issuer and
   subject (the release workflow identity) [S8]. A mis-signed image cannot be
   pulled at all.
2. *Broker-level*: before starting a container the broker checks the image
   digest against the release manifest and verifies the provenance attestation
   (source repo, workflow path, ref pattern). The relay images get the
   strictest policy: exact workflow identity, exact repo.

**Locally built images** (the promise implies forges may be built or extended
on the operator's machine): the base is verified as above; the local build
produces a local, unsigned image recorded in the audit log with
`{base digest, build recipe digest, inputs digest}`. Local images may be used
for *forges* only — never for relays or the gateway. Whether relays may ever
be locally built (development installs) is open [Q13].

**Third-party base images and packages.** Bases pinned by digest; package
installs inside image builds use lockfiles with hashes. In forges, dependency
installation is the T2 entry point and cannot be prevented, only contained:
I2 (nothing to steal) and I3 (nowhere to send it, beyond allowlisted
registries) are the controls, and install-script execution is disabled by
default where the ecosystem supports it.

**Offline / air-gapped verification.** Rekor inclusion proofs and the Fulcio
chain are bundled with the image (cosign bundle), so verification needs no
network once the artefact is local.

## 4. Models

Models differ from images in three ways: they are large, most publishers do
not sign them, and their licences are frequently not open-source licences.

**Identity.** A model is `{source, immutable revision, per-file sha256}`. Hub
revisions are pinned by commit hash, never by branch name. Fetch is resumable
and content-addressed; verification is per file before the file is made
visible to any consumer.

**Signature.** Where the publisher signs with the OpenSSF model-signing format
(Sigstore-based, a signed manifest of file digests) the fetcher verifies it
and records the signer [S9]. Where they do not, the product's own release
manifest vouches for the digests — which is a statement of "these are the
bytes we tested", not of origin; the record says which of the two applied
(`provenance: publisher-signed | product-pinned | operator-supplied`).
Operator-supplied models (a path or URL not in any manifest) are allowed,
labelled as such in the tray, and are approval-class on first use.

**Format safety.** Only data-only formats are loadable: safetensors, GGUF.
Pickle-based formats are refused outright, since unpickling is arbitrary code
execution [S10]. Chat templates and embedded metadata are treated as untrusted
input to the inference server; the inference container has no credentials, no
egress, and read-only weights, so a model that subverts its server gains a
sandbox with nothing in it.

**Model BOM.** Each model record carries what a CycloneDX ML-BOM would: base
model, quantisation, converter and version, licence, source URL [S6].

**Storage.** One content-addressed store, mounted read-only into inference
containers. Forges never get write access to weights.

## 5. Docs, cheatsheets, skills

- Authored content ships as a **bundle** with a digest in the release manifest
  and the same signature/provenance as an image (it can simply be an OCI
  artefact).
- Every document carries provenance front-matter: `source_url`, `retrieved`,
  `source_sha256` (of the page as retrieved), `licence`, `author`, `reviewed_by`.
  A build step refuses documents without it; an in-toto attestation over the
  bundle lists each document's source hash so "where did this sentence come
  from" has an answer [S5].
- Bundles are mounted read-only. An agent cannot edit the guidance other
  agents read. Agent-proposed changes go through the normal git path and a
  human review.
- Project-local instruction files (agent config in the repo) are **not**
  trusted — they are T6's lever. They can shape the agent's work but can never
  alter bindings, allowlists, or relay behaviour, which live outside the repo.
- Retrieved-at-runtime web content has no provenance and is treated as hostile
  input; I2/I3/I7 are the controls.

## 6. Licence-acceptance records (I11)

**Classification.** Every model/tool in a manifest has an SPDX identifier or
`LicenseRef-…` and a class:

| Class | Examples | Gate |
|-------|----------|------|
| permissive | MIT, Apache-2.0, BSD | none; recorded in the BOM |
| restricted | non-commercial (CC-BY-NC), share-alike, use-restricted (OpenRAIL family [S11]), revenue/seat thresholds, vendor EULAs | acceptance record required per project |
| unknown | no machine-readable licence | treated as restricted; the operator sees the raw text or a "no licence found" warning |

**Why per project.** The obligations attach to a *use*: a non-commercial model
may be fine in a hobby project and unlawful in a client project on the same
laptop. A machine-wide "I agree" would silently carry over.

**Acceptance flow.** A fetch of a restricted artefact for project P without a
record fails with a structured error. The agent cannot accept; it can only
surface the need. The tray then shows the licence **verbatim** (the exact
bytes whose hash goes in the record), the operator performs OS user
verification (same mechanism as I7 — acceptance is approval-class), and the
broker writes the record.

**Record.**

```yaml
schema: licence-acceptance/v1
project: <project id / repo>
artefact: {name, kind: model|tool, revision, digest}
licence: {id: SPDX-or-LicenseRef, text_sha256, source_url, retrieved}
class: restricted
obligations: [non-commercial, attribution, share-alike, ...]   # extracted, reviewed by the operator
accepted_by: <operator account label>
accepted_at: <RFC 3339>
verification: {method: touchid|hello|fido2|polkit, action_digest}
signature: <signature over the canonical record by a keystore-held key>
supersedes: <previous record digest | null>
```

**Where it lives.** In the project's repository, committed, so it travels with
the project, is reviewable, and survives a machine wipe; plus an audit event
(`licence.accepted`) on the machine. The licence text is stored alongside by
hash. Whether operators want acceptance records in a possibly public repo is
open [Q14]; the alternative is a per-project store outside the repo with only
a digest committed.

**Validity.** A record is valid for exactly `{project, artefact digest,
licence text hash}`. A new model revision or a changed licence text needs a new
acceptance. Records are never deleted, only superseded or revoked
(`licence.revoked` → the artefact is unmounted from that project's forges).

**What the record is not.** It is evidence that the operator was shown the
text and affirmed; it is not legal advice and does not check that the project
actually complies (e.g. really is non-commercial). The obligations list is
surfaced to agents as constraints, read-only.

**Signing key.** Per-install, generated in the keystore, non-exportable where
the platform allows. Loss of the key (vault wipe) does not invalidate old
records — the public key is committed with the first record — but new records
are signed by a new key, and the changeover is itself recorded [Q15].

## 7. What is deliberately not claimed

- Reproducible builds: desirable, not assumed.
- That signature = safe. Provenance says who built what from which source; it
  does not say the source is benign.
- That model provenance is solved. For unsigned models the product can only
  pin bytes.

## References

- [S1] OWASP Top 10 for LLM Applications 2025 (LLM01 prompt injection, LLM03 supply chain, LLM04 data and model poisoning) — https://genai.owasp.org/llm-top-10/
- [S2] The Update Framework — https://theupdateframework.io/
- [S3] Sigstore / cosign verification — https://docs.sigstore.dev/cosign/verifying/verify/
- [S4] SLSA v1.0 specification — https://slsa.dev/spec/v1.0/
- [S5] in-toto attestation framework — https://github.com/in-toto/attestation
- [S6] SPDX — https://spdx.dev/ ; CycloneDX ML-BOM — https://cyclonedx.org/capabilities/mlbom/
- [S7] GitHub artifact attestations — https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations
- [S8] `containers-policy.json(5)` (`sigstoreSigned`, Fulcio/Rekor requirements) — https://github.com/containers/image/blob/main/docs/containers-policy.json.5.md
- [S9] OpenSSF / Sigstore model signing — https://github.com/sigstore/model-transparency
- [S10] safetensors (rationale vs. pickle) — https://github.com/huggingface/safetensors
- [S11] Responsible AI Licenses (OpenRAIL) — https://www.licenses.ai/
