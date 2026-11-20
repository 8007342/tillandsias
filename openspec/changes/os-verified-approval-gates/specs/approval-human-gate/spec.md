## ADDED Requirements

### Requirement: the threat model is agents inside forges, gated by a human

Operator ruling 2026-11-16, verbatim: "Our current threat level is not
identity, is gating. We want to limit agents to perform actions without a
human gate, we don't care for certificates at this moment, we just want a
verifiable way of saying 'this was not a prompt, a classifier, an if
statement, this was very clearly a human clicking a button', that's what the
fingerprint touching does. It should as of now perform just the same bare
minimum guarantees on macos with touchid or on windows using windows hello,
we don't care for the signer, we just care for the human gate."

Operator clarification 2026-11-16: the adversary is an agent INSIDE a forge.
Agents running on the host are accepted as trusted for now; that gap is
documented here and is out of scope. Identity, certificates and signature
chains are out of scope.

The tray SHALL be the enforcer. It runs outside every forge, and no forge can
reach its state. A gated action (for example a cloud deploy) SHALL run only
after the tray has shown an OS human-presence prompt and the human has passed
it. Because the forge cannot reach host state, the OS yes/no result received
by the tray is sufficient evidence; no signature is required on this path.

#### Scenario: a host agent is outside this gate

- **WHEN** an agent running directly on the host performs an action
- **THEN** this requirement makes no claim about it; the gap is listed under
  "Later: host-agent-proof records"

### Requirement: a forge can only request a gated action

A forge agent SHALL be able only to REQUEST a gated action over its channel
to the tray. It SHALL NOT be able to perform the action, hold the credentials
the action needs, or produce anything the tray accepts as an approval. On
success the tray SHALL either perform the action itself or return a one-time
token bound to that action.

#### Scenario: a forge cannot self-certify

- **WHEN** a forge sends a request together with a fabricated approval,
  token or "approved" flag
- **THEN** the tray ignores it, shows its own OS prompt, and performs nothing
  until the human passes that prompt

### Requirement: the per-OS human-presence prompt

The tray SHALL use the native prompt of its OS:

- Linux: polkit action `org.tillandsias.approve`
  (`crates/tillandsias-headless/src/approval.rs:47`) with `auth_self`,
  satisfiable by fprintd. The policy is installed once by the operator with
  sudo into `/etc/polkit-1/actions` (yoga's polkit-127 reads that directory,
  measured).
- macOS: LocalAuthentication Touch ID with `biometryCurrentSet`. An
  `LAContext` SHALL NOT be held open across requests (macbookair-macos,
  work/2022-89hm, PR #1107).
- Windows: Windows Hello
  `IUserConsentVerifierInterop::RequestVerificationForWindowAsync(HWND)`,
  run by the Windows tray and never in the WSL2 guest (guest interop is off,
  rc=126, measured on yolanda-windows; Win11 26300 has Hello and a TPM 2.0,
  measured; the windows-tray has no Hello code yet; the API call is
  documented, unmeasured).

The approval SHALL carry an honest label naming the check that ran (for
example `polkit-fprintd`, `polkit-password`, `touch-id`, `windows-hello`).

#### Scenario: equal minimum on every OS

- **WHEN** a forge requests a gated action on Linux, macOS or Windows
- **THEN** the tray shows that OS's prompt and acts only on success

### Requirement: the approval binds to the exact action, once, briefly

The prompt SHALL show the action and its arguments, and the tray SHALL
execute exactly those arguments. An approval or token SHALL be valid for one
execution only and SHALL expire shortly after it is issued.

#### Scenario: arguments changed after approval

- **WHEN** a forge requests deploy X, the human approves, and the forge then
  asks to run deploy Y with the token
- **THEN** the tray refuses Y

#### Scenario: a token is replayed or late

- **WHEN** a used token is presented again, or a token is presented after it
  expired
- **THEN** the tray refuses it and performs nothing

### Requirement: no cached approvals

Every gated action SHALL require its own fresh prompt. A previous success,
an open authentication context, or a polkit retained authorisation SHALL NOT
satisfy a later request.

#### Scenario: two requests in a row

- **WHEN** a forge requests two gated actions in succession
- **THEN** the human is prompted twice

### Requirement: licence acceptance follows the merge-gated flow

Accepting a licence produces a durable record and is handled by the
merge-gated flow in its separate spec (`specs/approval-merge-gate`), not by
this action gate.

#### Scenario: a licence request

- **WHEN** a forge asks to accept a licence
- **THEN** the request is routed to the merge-gated flow

## Later: host-agent-proof records (out of scope, not normative)

Kept for when host agents stop being trusted or a record must convince a
process other than the tray:

- A live OS result (polkit exit status, `LAContext` boolean,
  `UserConsentVerifier` enum) proves presence only inside the process that
  received it. Only a signature by a key the OS releases on a human check is
  evidence to anyone else.
- STORED mode: a polkit-released software key on Linux; a Secure Enclave
  P-256 key (`.privateKeyUsage`, `.biometryCurrentSet`, falling back to
  `.userPresence`) whose SSHSIG verifies with stock
  `ssh-keygen -Y verify -n tillandsias-approval@v1` on macOS (the signature
  does not reveal whether biometry or the fallback ran, so the label is only a
  claim); a `KeyCredentialManager` TPM key on Windows (`RequestCreateAsync` at
  enrol, `RequestSignAsync(challenge)` per approval, documented, unmeasured).
  The verifier state would live outside every forge mount and be writable
  only by the host enrol path. The PKCS#1 v1.5 padding claim in fragment
  `20261027t170543z-0900ebc4-windows` is UNVERIFIED.
- WebAuthn with a Cloudflare Worker verifier, as researched by the
  coordinator.
- The polkit gap (a host agent running as the user can answer or bypass a
  user-session prompt) and a root-owned broker as its remedy.
- Deferred with them: signer identity, the allowed_signers trust anchor,
  FIDO2 ed25519-sk enrolment, and cross-host verification.
