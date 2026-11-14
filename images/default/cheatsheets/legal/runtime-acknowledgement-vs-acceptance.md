---
tags: [licence, click-through, acceptance, acknowledgement, webauthn, fido2, windows-hello, fprintd, secure-enclave, sshsig, consent-record]
languages: [rust, bash]
since: 2026-10-31
last_verified: 2026-10-31
sources:
  - https://www.w3.org/TR/webauthn-3/
  - https://fidoalliance.org/specs/fido-v2.1-ps-20210615/fido-client-to-authenticator-protocol-v2.1-ps-20210615.html
  - https://learn.microsoft.com/en-us/uwp/api/windows.security.credentials.keycredential.requestsignasync
  - https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/
  - https://learn.microsoft.com/en-us/windows/win32/api/webauthn/
  - https://fprint.freedesktop.org/fprintd-dev/Device.html
  - https://developer.apple.com/documentation/cryptokit/secureenclave
  - https://man.openbsd.org/ssh-keygen#Y
  - https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.sshsig
  - https://www.law.cornell.edu/uscode/text/15/7001
  - https://eur-lex.europa.eu/eli/reg/2014/910/oj
  - https://www.gnu.org/licenses/gpl-faq.html#ClickThrough
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---
# Runtime acknowledgement vs acceptance, and signing the record

@trace spec:cheatsheet-tooling, spec:approval-attestation, spec:approval-record
@cheatsheet legal/combining-licences-without-conflict.md, legal/openrail-use-restricted-model-licences.md

**This is not legal advice.** It separates what the licences require from
what Tillandsias chooses to show, and says plainly what a hardware-key
signature does and does not prove.

**Use when**: deciding which tier a new component's card gets, wording a
card, or implementing the signed acceptance record.

## Does a click-through matter at all?

- **Permissive and copyleft open-source licences do not require acceptance
  by the user.** They are conditional grants from the copyright holder: use
  is unrestricted, and the conditions bite only on redistribution. GPLv3
  section 9: "You are not required to accept this License in order to receive
  or run a copy of the Program." The FSF FAQ ("ClickThrough") notes a
  click-through neither helps nor hurts the GPL. MIT, BSD, Apache, MPL impose
  nothing on a user who only runs the software. A card that says "you must
  accept the MIT licence to continue" is **false** and should not exist.
- **Use-restricted and source-available licences bind the user by use.**
  OpenRAIL Attachment A, BUSL's Additional Use Grant, the NVIDIA container
  EULA ("By using the CONTAINER ... you accept"), Cloudflare's "By
  downloading, installing ... you agree". Here the user is a party, the terms
  are not visible unless someone shows them, and an informed act of assent is
  both the ethical thing and what the publisher's own text asks for.
- **Proprietary CLIs under account terms** (Claude Code) were accepted at
  account sign-up; the card's job is disclosure plus a record, not a new
  contract.

So: **two tiers, decided per register row, never a blanket prompt.**

| Tier | For | Card verb | Record | Blocks launch? |
| --- | --- | --- | --- | --- |
| `acknowledge` | MIT, BSD, Apache-2.0, MPL-2.0, (L)GPL components run as-is | "Got it" | unsigned `acknowledged` event, once per component+version | no: dismissable, shown once, listed under About |
| `accept` | OpenRAIL/RAIL, BUSL-1.1, NVIDIA container EULA, Cloudflare WARP, account-terms CLIs | "I accept" + hardware-verified signature | signed `accepted` statement | yes: the component does not start until the record exists |
| `refuse` | non-commercial, revenue-capped, gated, unknown licence | no card | register refuses the fetch | n/a (never launched) |

Research basis for the card itself: the first-use-download-consent spec
(`openspec/changes/os-verified-approval-gates/specs/first-use-download-consent/spec.md`)
already shows size and share before a big download; the licence card docks in
the same window so a user sees one sheet, not two dialogs. Permissive rows
should ride the About page and a single toast; do not interrupt first launch
for "got it" on every npm package (hundreds in the forge base) — aggregate
them per **image**, not per package.

## What a hardware-key signature proves, per platform

The operator's words: fingerprint and Windows Hello signatures as proof of
acceptance. What the platforms actually offer:

| Platform | Mechanism that **signs** | User verification gate | What it proves |
| --- | --- | --- | --- |
| Windows | `Windows.Security.Credentials.KeyCredentialManager.RequestCreateAsync` + `KeyCredential.RequestSignAsync` ("Prompts the user to cryptographically sign data using their key credential"), TPM-backed RSA; or WebAuthn platform authenticator via `webauthn.dll` (ES256) | Windows Hello face, fingerprint or PIN at sign time | the enrolled Hello user was present and verified on this device when the bytes were signed |
| macOS | Secure Enclave P-256 key (`SecureEnclave.P256.Signing.PrivateKey`) with access control `.biometryCurrentSet` or `.userPresence` | Touch ID, or password fallback | same, for this Mac's enclave |
| Linux with a FIDO2 security key | `ssh-keygen -t ed25519-sk -O verify-required` (libfido2, CTAP2 `getAssertion` with UV) | touch + PIN on the key | the key's holder was present and verified |
| Linux with only a fingerprint reader | **fprintd does not sign.** `net.reactivated.Fprint.Device` exposes Claim/Release/VerifyStart/VerifyStop/EnrollStart/EnrollStop and the `VerifyStatus` signal carrying `verify-match` / `verify-no-match`; no method returns key material or a signature. The reader answers a yes/no to a local process. | fingerprint (via polkit `auth_self`) | only that a polkit check passed in the process that then signs with a **software** key; the record must say `strength: software-password` or `software-biometric-local` |
| Linux with a TPM 2.0 | a TPM-resident key (`tpm2-tss`, or `ssh-tpm-agent`) can sign; UV is a PIN/password policy, not biometric | PIN | hardware-resident key signed; user verification is whatever policy was set |
| Any, no hardware | host software key, polkit-verified | password | the OS asked for the password; the key is software |

The approval broker designed in `openspec/changes/os-verified-approval-gates`
already enrols exactly these keys and emits SSHSIG records with a strength
field. **Reuse it.** A licence acceptance is a new statement kind in a new
SSHSIG namespace (`tillandsias-licence-acceptance@v1`), not a second key
system.

Honest framing for the operator: the signature is **non-repudiation of
assent on this device**, which is strong evidence that the person who could
unlock the device clicked "I accept" for these exact bytes. It is not an
electronic signature with a certification authority behind it, and whether a
court treats it as a signature is a matter of the applicable law
(US E-SIGN, 15 U.S.C. 7001, accepts any "electronic sound, symbol, or process
attached to ... a record and ... adopted by a person with the intent to sign";
EU eIDAS 910/2014 distinguishes simple, advanced and qualified signatures;
this would be at most "advanced" and only arguably). It proves the user's
assent to **us**; it does not make the licence more or less enforceable
against anyone.

## The acceptance statement

Canonical, line-oriented UTF-8, signed byte-for-byte (same style as the
approval statement in design D3):

```
tillandsias-licence-acceptance v1
component: nvidia-cuda-runtime
version: 13.3.1-runtime-ubuntu24.04
source: docker.io/nvidia/cuda@sha256:<digest>
licence_id: LicenseRef-NVIDIA-Deep-Learning-Container-2021-09-14
licence_url: https://developer.download.nvidia.com/licenses/NVIDIA_Deep_Learning_Container_License.pdf
licence_sha256: <sha256 of the text shown, as rendered to the user>
tier: accept
installation: <installation-uuid from vm-provisioning-lifecycle>
host: <hostname>
user: <OS account name>
strength: hardware-biometric | hardware-pin | hardware-presence | software-password
nonce: <128-bit random, broker-issued when the card opens>
accepted: 2026-10-31T18:02:11Z
```

Rules:

- `licence_sha256` is over the exact text the card rendered, so a changed
  licence invalidates old acceptances automatically; the register carries
  the same hash, and a mismatch between register and rendered text refuses.
- `licence_id` is an SPDX id when one exists, otherwise an SPDX
  `LicenseRef-` string (SPDX spec 2.3 section 10) we mint and keep stable.
- The nonce comes from the broker, so a record cannot be pre-built by an
  agent inside the forge; the forge may ask for a component, never accept
  for the user.
- `acknowledge` events use the same statement with `tier: acknowledge` and
  **no** signature; they exist for the About page and for "do not show
  again", not as evidence.

## Where it lives

- Signed records: appended to the host acceptance journal beside the approval
  journal (design D4, non-git actions), one file per installation, append-only,
  plus a copy at `$XDG_STATE_HOME/tillandsias/licences/<component>/<version>.sshsig`
  so the component's launcher can check it with
  `ssh-keygen -Y verify -n tillandsias-licence-acceptance@v1 -f <allowed_signers>`
  without talking to the broker.
- Not in git, not in the project repo: it is the user's record about the
  user's machine.
- A re-acceptance is needed when `licence_sha256`, `version` major, or
  `installation` changes; a version patch under the same licence hash
  inherits (register column `reaccept_on: text | version | never`).

## Common pitfalls

- Wording an acknowledge card as a condition ("you must agree") for MIT code.
- Prompting per npm package instead of per image.
- Treating `verify-match` from fprintd as a signature; it is a boolean to a
  local process.
- Letting the forge (an agent) pass the card: the broker is outside the forge
  by design; the licence card must be too.
- Hashing a summary instead of the shown text.
- Storing the record in the project repo, where it would be pushed with a
  work ref.

## Provenance

- <https://www.w3.org/TR/webauthn-3/> — assertion ceremony, `userVerification`, platform vs roaming authenticators
- <https://fidoalliance.org/specs/fido-v2.1-ps-20210615/fido-client-to-authenticator-protocol-v2.1-ps-20210615.html> — CTAP2 `authenticatorGetAssertion`, UV flag
- <https://learn.microsoft.com/en-us/uwp/api/windows.security.credentials.keycredential.requestsignasync> — "Prompts the user to cryptographically sign data using their key credential." (fetched 2026-10-31)
- <https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/> — Hello key storage (TPM) and gestures
- <https://learn.microsoft.com/en-us/windows/win32/api/webauthn/> — `WebAuthNAuthenticatorGetAssertion`
- <https://fprint.freedesktop.org/fprintd-dev/Device.html> — Device interface: no signing method (fetched 2026-10-31)
- <https://developer.apple.com/documentation/cryptokit/secureenclave> — Secure Enclave signing keys with access control
- <https://man.openbsd.org/ssh-keygen#Y> and <https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.sshsig> — `-Y sign` / `-Y verify`, namespaces
- <https://www.law.cornell.edu/uscode/text/15/7001> — E-SIGN definition of electronic signature
- <https://eur-lex.europa.eu/eli/reg/2014/910/oj> — eIDAS signature levels
- <https://www.gnu.org/licenses/gpl-faq.html#ClickThrough> — click-through and the GPL; GPLv3 section 9 at <https://www.gnu.org/licenses/gpl-3.0.html>
- Derived (not provenance): `openspec/changes/os-verified-approval-gates/design.md` D1-D4 and `specs/first-use-download-consent/spec.md`, read 2026-10-31.

## See also

- `legal/combining-licences-without-conflict.md`
- `legal/openrail-use-restricted-model-licences.md`
- `legal/busl-1-1-hashicorp-vault.md`
- `legal/proprietary-eulas-in-the-stack.md`
