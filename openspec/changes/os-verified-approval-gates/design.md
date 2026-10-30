## Context

Cost-bearing actions reach the cloud through three host-side doors:

1. **Host MCP tools.** `handle_mcp_jsonrpc` (crate `tillandsias-headless`,
   module `mcp_socket`) dispatches `tools/call` for the host services, the
   `browser.*` family and the `cloudflare.*` family (`cloudflare_mcp::call_live`,
   read-only today). Order 1853-qr4h adds a write tool,
   `ensure_github_cloudflare_worker`. The forge reaches these over a per-lane
   socket whose identity comes from the listener's `LaneIdentity`, never the
   request.
2. **The git mirror.** `images/git/pre-receive-hook.sh` validates ledger YAML,
   reads the project's branch-discipline seed (`discipline_parse`,
   `DISC_INTEGRATION`, `DISC_DEFAULT`) and then relays the ref transaction
   upstream before accepting it. A push that reaches an integration or default
   branch on GitHub starts Actions.
3. **Host scripts and host agents.** `gh workflow run` in release scripts and
   skills (`merge-to-main-and-release`), PR creation and merges through `gh`.

User-facing surfaces today are thin: Linux uses `notify-send`
(`notify_github_refresh_expiring`, `notify_cert_expiring`), macOS uses
`osascript display notification` (`notify_provisioning_failed`,
`notify_crash_loop`), Windows uses a notify-icon balloon. The Linux tray is a
StatusNotifierItem over `zbus` with no window toolkit. Startup progress is the
cumulative `TrayStatusStage` label (`status_label`), visible only in the menu.

Mācron canon lives in the macron.dev repository
(`assets/Tlatoāni + Mācron cannon guidelines.md`): a small cream/ivory robot
with teal accents, dark face display with cyan indicators, a small antenna,
a modular right arm, eager and helpful, drawn from a few simple shapes,
recognisable at icon scale. Tillandsia art already exists in this repo under
`assets/icons/<species>/{bud,bloom,dried,pup}.svg`.

## Goals / Non-Goals

**Goals**
- No cost-bearing action reaches the cloud through Tillandsias-owned doors
  without a fresh, action-bound approval the OS verified.
- The approval is a cryptographic signature by a per-host key that the OS
  releases only after a user check, and it is verifiable later by the mirror.
- One record format on all three platforms, verifiable with stock
  `ssh-keygen` in the Alpine git image.
- Calm, honest UX: the dialog says what happens and what it costs.

**Non-Goals**
- Stopping a host agent that holds the operator's raw `gh` credentials from
  calling GitHub directly. That door is closed by GitHub-side rules (see Open
  Questions), not by this change.
- Remote attestation of the hardware to a third party. The mirror trusts the
  enrolled public keys it was given at enrolment.
- Implementing the download manifest itself (PR #650's change owns it).

## Decisions

### D1. Enrolled per-host keys, not a bare "OS said OK"

A yes/no API (`UserConsentVerifier`, polkit `CheckAuthorization`, plain
`LAContext.evaluatePolicy`) proves the check happened only to the process that
asked. Anything downstream (the mirror, a later audit) must trust that process.
A signature by a key the OS releases only after the check is proof that
travels. So each host enrols one **approval key**:

| OS | Key | Unlock | Hardware | Attestation |
|----|-----|--------|----------|-------------|
| macOS | Secure Enclave P-256 (CryptoKit `SecureEnclave.P256.Signing.PrivateKey`, access control `.privateKeyUsage` + `.biometryCurrentSet`, falling back to `.userPresence`) | Touch ID; Mac password when no Touch ID | Apple silicon or T2 (Secure Enclave) | Yes: SE signature |
| Windows | Windows Hello key credential (`KeyCredentialManager.RequestCreateAsync`, `KeyCredential.RequestSignAsync`), RSA-2048 in TPM | Hello face, fingerprint or PIN | TPM 2.0 (present on Windows 11 hosts) | Yes: Hello signature; key attestation via `GetAttestationAsync` |
| Linux | FIDO2 security key, `ssh-keygen -t ed25519-sk -O verify-required` (libfido2) | YubiKey touch plus PIN | FIDO2 key (operator will get a YubiKey) | Yes: authenticator signature |
| Linux fallback | Host ed25519 key whose private half is sealed in Vault, released by the broker only after a polkit `auth_self` check (password, or fprintd where a reader exists) | Login password | none | Signature yes, hardware no: record says `software` |

The yes/no APIs are kept only as the fallback prompt on hosts without the
hardware, and the record states which strength was used.

Rationale for the macOS choice: a Secure Enclave key stored as its wrapped
`dataRepresentation` blob in the app's support directory needs no
keychain-access-group entitlement, so it works for the ad-hoc signed tray;
the enclave enforces the biometric policy at signing time.

### D2. One signature format: SSHSIG

`SSHSIG` (OpenSSH `PROTOCOL.sshsig`) is what git already uses for SSH-signed
commits and tags, and `ssh-keygen -Y verify -n <namespace> -f allowed_signers`
verifies it. It supports `sk-ssh-ed25519@openssh.com` (Linux FIDO2),
`ecdsa-sha2-nistp256` (macOS Secure Enclave, SHA-256, exactly what CryptoKit
P-256 signs) and `rsa-sha2-256` (Windows Hello RSA if the padding is
PKCS#1 v1.5). The macOS and Windows signers build the SSHSIG envelope
themselves around the platform signature; only Linux uses `ssh-keygen -Y sign`.
Namespace: `tillandsias-approval@v1`.

Windows caveat: Microsoft documents Hello signatures as RSA with SHA-256; if
hardware shows PSS padding, `rsa-sha2-256` SSHSIG cannot carry it and the
Windows signer falls back to a WebAuthn platform-authenticator (ES256) key via
`webauthn.dll`, which SSH represents as `sk-ecdsa-sha2-nistp256@openssh.com`.
The Windows packet's first step is to measure this on hardware.

### D3. The approval statement

Canonical, line-oriented UTF-8, signed byte-for-byte:

```
tillandsias-approval v1
action: merge-into-integration
project: <project label>
target: refs/heads/linux-next
from: <old sha>
to: <new sha>
detail: Merge work/1879-5jkt into linux-next
host: <hostname>
forge_instance: <instance id>
forge_agent: <agent>
forge_project: <project label>
forge_launched: 2026-10-25T13:40:00Z
strength: hardware-biometric | hardware-pin | hardware-presence | software-password
nonce: <128-bit random, broker-issued>
issued: 2026-10-25T14:02:11Z
expires: 2026-10-25T14:12:11Z
```

The forge never sees the nonce before approval; the broker issues it when the
dialog opens, so a replay or a pre-built statement fails. `expires` is ten
minutes after issue; a stale approval is re-asked, not extended.

### D4. Where the record lives

- **Git actions** (push to an integration or default branch, merge): a git note
  under `refs/notes/tillandsias/approvals`, attached to the `to` commit, whose
  body is the human sentence on the first line, the statement, then the armored
  SSHSIG. The note ref update rides in the same `git push --atomic` as the
  branch update, so `pre-receive` sees both. Notes keep the commit hash
  stable (a trailer cannot be added to a commit that already exists) and are
  append-only per commit.
- **Merge commits created by host tools** additionally carry a trailer, so the
  approval is visible in `git log` without notes configured:
  `Approved-by: the operator, with Touch ID on macneo`. No hash is printed.
- **Non-git actions** (workflow dispatch, Cloudflare, remote worker): the
  broker appends the note body to a host approval journal
  (`approvals.jsonl` in the tray's state directory) and, when the action names
  a commit (a workflow run on a ref, a Worker deploy of a revision), also
  writes the note on that commit.

Signed tags and signed commits were rejected for the record: they would sign
the content, not the act of sending it to a costly place, and a re-push of an
already-signed commit would look approved.

### D5. What `pre-receive` verifies

For each ref update whose refname equals the seed's integration or default
branch (from `discipline_parse`, never a constant): find the note for `NEWSHA`
in the pushed `refs/notes/tillandsias/approvals` tip, parse the statement,
require `target`, `from`, `to` and `project` to match the update exactly,
require `expires` in the future, then run
`ssh-keygen -Y verify -n tillandsias-approval@v1 -I operator -f <allowed_signers>`
with the statement on stdin. The allowed-signers file lives in the mirror's
private state (not the repo), written by enrolment on the host. On failure the
push is refused before the relay with one plain sentence and the remedy.
`advised`/`warn` enforcement words from the seed apply so a project can adopt
the gate gradually; the Tillandsias project seeds it `enforced`.

### D6. The gate in host tools

A static gate table in the headless crate names each cost-bearing tool or
action with its curated sentence key. `handle_mcp_jsonrpc` consults it before
dispatch. A gated call without a matching broker approval returns, without
contacting any cloud API:

```json
{"state": "awaiting_approval", "approval_id": "…", "retry_after_s": 5,
 "message": "Waiting for the operator to approve on this computer."}
```

The broker opens the dialog on the host. The agent polls; it cannot approve,
because approval requires the OS check and the key never leaves the host.
Arguments an agent passes named `approval`, `approved` or similar are ignored.
A refusal returns `state: declined`, and the agent is told not to retry the
same request in this session.

Host scripts call `tillandsias approval request --action <kind> --detail <s>`
which blocks for the dialog and prints the record path; `gh workflow run` is
wrapped by it.

### D7. Dialog and splash rendering

- macOS: AppKit `NSPanel` at normal window level (not floating); LAContext's own
  sheet appears after the operator presses Approve.
- Windows: a small Win32 window; Hello's own prompt appears after Approve.
- Linux: a separate small binary `tillandsias-approval-dialog` using GTK4
  (present on Fedora Silverblue and Workstation), launched argv-only by the
  broker; the polkit agent or the security-key touch prompt follows Approve.
- Art: Mācron poses as SVG, drawn to the canon, one per action kind
  (dispatching a workflow, merging, starting a remote worker, raising a
  Cloudflare antenna, carrying a big crate for downloads), placed in a workbench
  scene framed by the existing tillandsia species SVGs. Static on the
  dialog, so no motion competes with reading.
- Splash: the same window class at normal level, never `always-on-top`,
  focusable and closable; a closed splash leaves the tray running. Each
  `TrayStatusStage` maps to one Mācron step (unpacking crates, connecting
  pipes, warming the kiln, opening the workshop door). Animation advances only
  on stage events; within a stage Mācron loops a small idle motion for up to
  the stage's expected duration, then stops and shows a quiet "this step is
  taking longer than usual" line. Shutdown reverses the scene.

### D8. Curated sentences

Every gated action has a fixed sentence pair in a table, not generated text:
**what happens** and **what it costs**. Rules: second person, present tense,
numbers when known, no capitals for emphasis, no exclamation marks, none of
the words "danger", "warning", "critical", "irreversible" unless literally
true, and every consequence names the way back. Example for a workflow
dispatch: "GitHub will run the release workflow for linux-next." / "This uses
about 40 minutes of your GitHub Actions time. You can cancel the run from
GitHub while it runs." A lint test enforces the rules.

### D9. Download window and disk bar

Disk figures come from the OS: macOS `URLResourceValues`
`volumeTotalCapacity`, `volumeAvailableCapacityForImportantUsage` (counts
purgeable space) and, where readable, the system volume size from the sealed
system volume; Windows `GetDiskFreeSpaceExW` plus the Volume Shadow Copy
storage size for backups where the query is permitted; Linux `statvfs` on the
storage root, with Tillandsias' share measured from its own storage root.
OS/apps/backups segments are shown only when the platform reports them; a
segment that cannot be measured is folded into "Other" rather than guessed.
Tillandsias' share and the planned download come from the download manifest of
PR #650's change, split into **needed** (forge and web images) and **removable**
(models, caches; deleted and recreated on demand).

## Risks / Trade-offs

- [The operator is away and an agent waits] → `awaiting_approval` is
  non-blocking with `retry_after_s`; agents move on to other work.
- [Approval fatigue leads to blind clicking] → only cost-bearing actions are
  gated, each shows a concrete cost; batching several pushes into one approval
  is an open question rather than a default.
- [Lost YubiKey or reinstalled OS] → enrol a new key from the tray; old keys are
  removed from allowed-signers; nothing is recovered (consistent with the
  vault-is-thrown-away ruling).
- [Notes refs are unfamiliar and may be dropped by tooling] → the trailer and
  the host journal duplicate the human sentence; the mirror is the enforcement
  point, not GitHub.
- [Windows Hello padding mismatch] → measured first; WebAuthn fallback
  designed (D2).

## Migration Plan

1. Land the broker, the record format and Linux enrolment with the gate in
   `warn` mode for the Tillandsias seed.
2. Land the pre-receive verifier; flip the seed to `enforced` once every active
   host has enrolled.
3. macOS and Windows signers land on their hosts; until then those hosts' pushes
   to integration branches are refused under `enforced`, which is the intent.

## Open Questions

See the tasks file section 9; summarised in the PR body.

## Operator rulings, 2026-10-25 (second round)

These rulings supersede D3 to D6 where they conflict.

### R1. Grants, with four choices in the window

The dialog offers **Approve this time**, **Approve for 10 minutes**,
**Approve for 2 hours** and **Approve this session**, plus Not now. A grant is
per action class and target (for example `workflow-dispatch` on
`release.yml@main`, or `cloudflare-deploy` on Worker `macron-dev`), never
global, and bound to ONE forge instance (operator ruling 2026-10-26). A
covered request proceeds with no prompt only when the requesting forge is the
instance named in the grant. A second concurrent forge on the same project
with the same agent gets its own, separate grants. The window says so plainly
("Approvals here apply only to this forge.") under a metadata line
`<Agent>/<Project>/Launched at <YYYY-MM-DD HH:MM>`. "This session" ends when
that forge stops, not when the tray exits. Grants wider than one forge come
later and are not offered yet. When it arrives, a standing grant ("don't ask
me again for this") has no expiry and
is offered only from the tray's grant list, not the dialog, so it is never a
reflex click.

Grant statement (signed by the device key as SSHSIG, D2):

```
tillandsias-grant v1
action: workflow-dispatch
target: 8007342/tillandsias release.yml@main
scope: once | 10m | 2h | session | standing   (standing deferred, see above)
host: <hostname>
forge_instance: <instance id, unique per forge launch>
forge_agent: <agent>
forge_project: <project label>
forge_launched: 2026-10-25T13:40:00Z
strength: hardware-biometric | hardware-pin | hardware-presence | software-password
issued: 2026-10-25T14:02:11Z
expires: 2026-10-25T14:12:11Z      (absent for standing)
nonce: <broker-issued>
```

A `once` grant is consumed by its single use: the broker records the nonce as
spent.

### R2. Grants live in Vault, and the signature is what counts

Grants are stored at `secret/tillandsias/approvals/grants/<host>/<forge-instance-id>/<action>/<target-hash>`.
A verifier refuses a grant whose `forge_instance` differs from the requesting
forge's, even if the agent, project and target match.
Vault policy: only the approval broker's role may write. Only the named
service roles may read: `git-mirror-hook`, `mcp-gate`, `release-tooling`.
The Vault file audit device is on. Verifiers check the signature against the
enrolled allowed-signers and check the expiry. Being present in Vault proves
nothing, so a Vault compromise cannot forge a grant: the device key never
enters Vault. A missing or invalid grant, for example after a Vault wipe (per
the vault-is-thrown-away ruling), means the system asks again and stores a new
grant. Standing grants are verified by the git-mirror hook against the
allowed-signers file kept in mirror state, which only the host writes.

Each grant record carries `last_authorized` (the issue time of its latest
signature) and `scope`, so the tray grant list can say "approved 2 hours ago,
for 2 hours".

On Linux hosts with SELinux enforcing, a policy module labels the broker
binary and its socket, so only the broker domain can connect to the grant
store's local endpoint and read its Vault token file. Forge containers
(`container_t`) are denied both.

### R3. Trail: signed append-only journal plus the Vault audit log

**Recommendation: keep both, with the signed journal authoritative.** The
Vault audit log alone is not enough:

- it is lost when the vault is wiped and rebuilt, which is the standing remedy;
- it records requests with HMAC'd values, so it shows that something was
  written, not what the operator approved;
- the same administrative position that can tamper with Vault can disable an
  audit device;
- it is not signed by the device key, so it does not prove a human approved.

The journal is a hash-chained, append-only sequence of the signed grant and
use statements, kept as git notes under `refs/notes/tillandsias/approvals` in
the mirror. The mirror's pre-receive hook refuses non-fast-forward updates of
that ref. It survives Vault wipes, every entry verifies on its own, and the
chain shows deletions. The Vault audit log stays on as the access trail:
which service read which grant, and when.

### R4. Rollout modes per host

Each host has one explicit mode, shown in the tray menu ("Approvals: present",
for example) and in `tillandsias --diagnose`:

- `present`: the host has enrolled approval hardware (macOS Touch ID, Windows
  Hello fingerprint, which is the Windows test platform, or a FIDO2 key).
  Gated actions show the dialog, and a declined action does not run.
- `allow`: no approval hardware. Gated actions run, and each is journaled as
  "not enforced: no approval hardware". macuahuitl is in `allow`.
- `enforced`: later, by explicit operator decision only, once macuahuitl-like
  hosts have a YubiKey or an equivalent path. A missing grant is refused.

The mode is host state written by the broker from the operator's tray action.
No agent can change it, and no gate silently falls back to a weaker mode.

### R5. Budgets: routine work needs no approval

The budget policy covers the daily build, N optional extra builds per day
(default 3) and the daily promotion to stable. It is not gated. Only
out-of-band actions are gated: over-budget releases and cloud actions outside
the policy. The policy and its counters live in Vault under
`secret/tillandsias/approvals/budget`, writable only by the broker and
release tooling, never by agents. Counters reset at 00:00 UTC.

### R6. Promotions in branch discipline

Merges and PRs are promotions in the production chain. The branch-discipline
seed (`.tillandsias/branch-discipline.yaml`) gains an optional
`promotions:` list. Each entry has `from`, `to` and `approval: required | none`,
for example `research/* -> linux-next: required`. The pre-receive hook gates
only the promotions marked required. Nothing is gated by default, and this
supersedes D5's blanket integration-branch gate.

### R7. Art

The dialog's Mācron illustrations are generated by the project's own
image-generation infrastructure (change `local-image-generation`, tool
`image.generate`, order 1874-kkrc). Generated assets are staged and need
operator approval before they ship. The approval flow is an ordinary gated
action of class `publish-asset`.
