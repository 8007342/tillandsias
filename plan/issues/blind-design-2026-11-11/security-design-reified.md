# reified.md — the security design on the real constraints

The same design as `credential-design.md`, `threat-model.md`,
`supply-chain.md` and `audit-checklist.md`: one host-side broker, one vault,
short-lived scoped tokens handed only to relays, forges that hold nothing,
identity by channel, OS-verified approval for cost and destructive actions,
digest-plus-signature verification of everything an agent runs or reads.
Sections not mentioned are unchanged. Every change is marked `[R:<reason>]`:
an operator ruling (memory name), an answer in `answers.md` (S-Qn), or an open
operator question (OQ-n in ../../operator-questions.md). Nothing is taken from
the existing implementation unless a ruling forces it.

## 0. Status of the blind assumptions

| Blind assumption | After answers |
|---|---|
| Subscription login usable through the gateway (Q1) | HELD: OQ-16. Until answered, subscription-login agents are the I2 exception of §7 case 3, visible and counted. |
| Which CLIs run with no local credential (Q2) | unknown (S-Q2: not recorded); the audit must count the exceptions. |
| Shared public GitHub App, device flow (Q3) | CONFIRMED and made exclusive, §7 |
| Own machine with project-only mounts on macOS (Q4) | KEPT as the design's requirement |
| Headless Linux via FIDO2 or passphrase unlock (Q6) | CHANGED, §3 |
| Linux approval by FIDO2 or polkit+fprintd (Q7) | CONFIRMED by ruling ("fprintd or a YubiKey") |
| Same-UID attacker out of scope (Q8) | HELD: OQ-17 |
| FDE recommended, not relied on (Q9) | HELD: OQ-18. Swap is mandatory by ruling, so the locked-memory requirement for broker and relays is load-bearing on every platform. `[R:operator-approval-and-ux-rulings — swap is mandatory]` |
| Cloudflare parent token entered by hand (Q10) | CHANGED, §7 |
| Relays never locally built on release installs (Q13) | KEPT (the existing system builds locally, but that is not a ruling) |
| Licence records in the project repo (Q14) | CONFIRMED, with field changes, supply chain §6 |
| New signing key after wipe (Q15) | HELD: OQ-19 |
| Single machine (Q16) | HELD: OQ-4. Identity-by-socket is kept and must stay replaceable by attested workload identity later. `[R:methodology capability_ladder; identity_plane_aspiration]` |
| Unattended runs queue approval-class verbs (Q19) | CHANGED, §8 |

## Credential design

### §2 Invariants
I1–I14 unchanged in wording except:
- **I7** — "fresh OS user verification bound to a digest of the exact action"
  holds for the first approval of a kind in a forge instance and for every
  licence acceptance; it is not re-asked per call (§8). `[R:approvals-are-standing-until-expiry-enforced]`
- **I9** — the persistent audit log is HELD: OQ-6, OQ-7, OQ-8 (see §9).
- Every invariant is asserted and reported per platform (Linux, macOS,
  Windows) as its own verdict. `[R:obligations-hold-per-platform]`

### §3 Components
- **Vault.** One AEAD file whose data key is wrapped by the OS keystore:
  unchanged for macOS, Windows and Linux with an unlocking keyring. The
  Linux "no keyring" row changes: no passphrase and no FIDO2-wrapped file.
  Without an unlocking keyring the broker runs without a vault and grants live
  in locked memory for the session only. `[R:no-plaintext-credentials-at-rest — "only OS-encrypted stores … or memory"]`
  `[R:S-Q6 — operator: an unlocking keyring is the requirement to survive]`
- **Wipe, no recovery (I8):** unchanged; this is the operator's rule verbatim.
  Sign-in must therefore be frictionless because it may recur. `[R:vault-is-thrown-away-not-recovered]`
- **Broker:** host process, unix socket or ACL'd named pipe, no TCP:
  unchanged. Written in Rust; policy tables as Lua data; relays in Rust or Go.
  No shell, Python or jq in broker, relays or their install path.
  `[R:operator direction — Lua/Rust/Go, minimise bash and python, no jq]`
- **Relays:** unchanged. The deploy relay is constrained in §7.
- **Substrate.** The design's "the VM must mount only project directories,
  never the home directory" and "interop and automount off" stand as
  requirements. Nothing is installed on a host with sudo or by layering
  packages; anything the broker needs beyond the OS runs in a container.
  `[R:no-sudo-no-layering-no-licence-without-operator]`

### §4 Identity and scoping
Unchanged, plus: several forge instances of one project are the normal case,
so the per-forge socket (not the per-project network) is always the identity
key, and grants and approvals are namespaced per forge instance.
`[R:operator-approval-and-ux-rulings 2026-11-01, 2026-10-26]`

### §5 Lifetimes, rotation, revocation
Unchanged. "Keeps retrying" a failed upstream revocation is a new cadence: it
retries at minutes, not seconds, and is listed for approval.
`[R:polling-cadence-needs-operator-approval]`

### §6 How a secret reaches its consumer
Unchanged, including "`podman secret` is not used with the file driver".
`[R:no-plaintext-credentials-at-rest — names a file-driver podman secret as a defect]`
Agent transcripts and forge home content die with the forge, so "persisted and
scanned on stop" is removed as an option: the agent home is ephemeral.
`[R:forge-logs-die-with-the-forge]`

### §7 Login flows
- All sign-ins start from the tray; an agent can never start one.
  `[R:agents-never-start-a-sign-in]`
- **GitHub.** The shared GitHub App device flow is the **only** path and the
  only source of git identity; the fine-grained-PAT fallback is removed.
  Commits are authored as the human, agents credited in `Co-Authored-By`.
  `[R:open-it-browser-direction — git identity, "the ONE source"]`
- **Model providers.** Order of preference unchanged; case 1 is HELD on OQ-16.
  Usage messages say honestly that a metered provider bills the user's account
  even at zero cost. `[R:operator-approval-and-ux-rulings 2026-10-26]`
- **Cloudflare.** Primary path is the OAuth sign-in from the tray
  (authorization code with PKCE, with a QR variant through an approved
  redirect), not a hand-entered parent token. `[R:cloudflare-relay-redirects-approved]`
  Every create or refresh of a hosted resource and **every** deploy, preview
  included, is approval-class; the "preview deploys are not approval-class,
  subject to a daily cap" clause is removed. No deploy is triggered by a push;
  a deploy is an explicit act for a named revision. The product's own sites
  are never auto-deployed; a user project may opt in.
  `[R:operator-approval-and-ux-rulings — approval gate for cloud-cost actions]`
  `[R:cloud-builds-are-intentional-only]` `[R:no-auto-deploy-for-own-sites]`
- **Local inference / model downloads.** Unchanged.

### §8 Approval
- **Verbs.** The starting set is the nine approved kinds: workflow dispatch,
  push to an integration branch, merge to an integration branch, open pull
  request, promote stable, extra build, remote worker, hosted resource, hosted
  deploy. The design's further verbs (force-push or delete of a non-agent ref,
  CI-file changes, widening a binding, the I2 exception, licence acceptance)
  are kept as additions. `[R:operator-approval-and-ux-rulings 2026-10-26]`
- **Session grants exist.** "No approve-all for this session" is replaced by:
  "approve this session" is offered and means **this forge instance**
  (`<Agent>/<Project>/Launched at <date time>`, shown on every window). A
  concurrent forge on the same project has its own grants. Grants expire per
  session or time; until expiry is enforced they hold, and there are no
  per-call re-asks. Licence acceptance is the exception: always per record.
  The ≤ 60 s single-use assertion bound to digest `d` remains the mechanism
  for the first approval and for licences.
  `[R:operator-approval-and-ux-rulings 2026-10-26]` `[R:approvals-are-standing-until-expiry-enforced]`
- **Unattended runs.** An unattended forge works inside the grants its
  instance already holds; a kind it does not hold waits for the human. An
  agent or peer can never create spend authority for the operator.
  `[R:a-peer-cannot-commit-operator-spend]`
- **Prompt.** Rendered from structured fields with fixed templates, as
  designed, in the product's minimal illustrated dialog; wording is honest and
  never alarming; durations as ranges. `[R:operator-approval-and-ux-rulings]`
- **Evidence.** The approval is a signature by a key the OS releases only
  after verification, and it is recorded on the commit or push it authorised.
  What is published carries no personal data: an opaque enrolment id instead
  of a hostname, no device or biometric type, detail built from a template
  (a statement containing a home path or an email is refused before signing),
  project given as the repo slug. Keys are per project so approvals cannot be
  linked across projects. Hardware attestations stay on the host.
  `[R:operator-approval-and-ux-rulings 2026-10-27]`
- **Linux.** FIDO2 key or fingerprint through polkit, as designed. Hosts with
  neither lose approval-class verbs (the design's choice; kept).

### §9 Audit events
HELD on OQ-6 (may anything persist), OQ-7 (fail closed) and OQ-8 (may it name
an account). The restrictive default until answered: events are emitted live
to the tray; a persisted log, if allowed, holds typed fields and opaque ids
only — no account labels, and exact egress hosts only if OQ-9 allows.
`token_fp` and the hash chain are unchanged. `[R:forge-logs-die-with-the-forge]`

### §10 Failure behaviour
Unchanged. Tray wording for each row is one curated sentence; no retry button:
failures retry automatically a bounded number of times, then show failed.
`[R:image-build-retry-and-tray-feedback-ruling]`

## Threat model

- §1 diagram and §4 table: "podman machine" is kept as the design's substrate
  on macOS and Windows, with the macOS provider fixed to libkrun.
  `[R:media-studio-and-storage-direction 2026-10-28 — krunkit/libkrun approved]`
- The product uses its own podman store on Linux, so "other containers of the
  user" are outside B2 by construction. `[R:operator-approval-and-ux-rulings — own podman store]`
- Linux default holes: the isolated preview browser receives only the Wayland
  display socket, never the whole runtime directory. `[R:open-it-browser-direction]`
- A confined host helper for NPU or Metal inference (no internet, OS sandbox,
  one socket into the region) is a permitted component; it is a new asset on
  the host side of B2 and gets its own STRIDE row: no credentials, no egress.
  `[R:open-it-browser-direction — host helpers approved]`
- On-demand appliances (web container, browser, studio) started at a forge's
  request are new B3 neighbours: same project network, no credentials, started
  by the broker's side, never by handing the forge an engine socket.
  `[R:operator-approval-and-ux-rulings 2026-11-02]`
- Residual 4 (same-UID process): HELD, OQ-17. Residual on hibernation and
  swap: HELD, OQ-18.
- Per-platform table rows are obligations with separate verdicts.
  `[R:obligations-hold-per-platform]`

## Supply chain

- §2–§3: manifest, digests, keyless signing, provenance, engine-level
  `policy.json` on the product's own store: unchanged. Hosted builds are
  intentional and at most one a day; nothing builds per commit.
  `[R:one-cloud-build-per-day]` `[R:cloud-builds-are-intentional-only]`
- §4 Models: unchanged, plus: a restricted-licence model is offered only
  behind a durable acknowledgement and is never bundled; selection starts with
  the smallest model and offers one tier larger at a time; nothing metered
  beyond the two accepted free tiers is recommended.
  `[R:licence-acknowledgement-direction]` `[R:operator-approval-and-ux-rulings — small model first; no commercial-capped services]`
- Any third-party component the product itself would bundle or accept terms
  for goes to the operator first. `[R:no-sudo-no-layering-no-licence-without-operator]`
- §5 Docs: unchanged; provenance front-matter is the rule.
- §6 Licence records: kept in the project repository, committed. Record
  fields change: `accepted_by` is not an account label and
  `verification.method` is removed (no personal data, no device or biometric
  type); the host is an opaque enrolment id; the signing key is **per
  project**, not per install. What happens to old records after a vault wipe:
  HELD, OQ-19. `[R:operator-approval-and-ux-rulings 2026-10-27]`

## Audit checklist

- Rules 1–6: unchanged (assert the population; three verdicts; never print a
  match; run on each platform).
- The checklist is delivered as one read-only subcommand in Rust with pattern
  tables as Lua data, run from a container, instead of host shell pipelines;
  no jq, no Python, no ad-hoc bash. `[R:operator direction]` `[R:no-host-tools-ever]`
- Row 4.9's `sudo find` on the VM is replaced by the same search as the guest's
  unprivileged product user plus a read-only inspection of the VM image from
  the host; the audit never uses sudo on a bare-metal host.
  `[R:no-sudo-no-layering-no-licence-without-operator]`
- §7 (approvals): checks that session grants are namespaced to one forge
  instance and that licence acceptance is never covered by a session grant.
  `[R:operator-approval-and-ux-rulings 2026-10-26]`
- §9 (audit log) and row counts for I9: NOT RUN until OQ-6 is answered.
- §11 (licence records): adds "the committed record contains no hostname, no
  account label, no device or biometric type". `[R:operator-approval-and-ux-rulings 2026-10-27]`
- Report: one verdict per (invariant, platform); no aggregate row.
  `[R:obligations-hold-per-platform]`
