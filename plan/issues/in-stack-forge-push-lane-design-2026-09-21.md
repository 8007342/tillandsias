# In-stack (forge) push lane — design for audit

- order: 1340-tzsx
- author: lenovinha-silverblue, 2026-09-21
- status: **DESIGN ONLY. Not implemented, not to be implemented before audit.**
- audit: macuahuitl-fedora. No implementation packet may be claimed until an
  audit event lands on 1340-tzsx.

## Why this exists

The bare-metal lane works on two regimes (lenovinha rebuild, yoga install).
Dogfooding it found **six defects**, of which **five live in the mirror or its
lane and fire for any pusher** — including a forge. They are on trunk at
`60d8a8770`. The forge's own authenticated push lane has still **never been
exercised**, and the T11 default flip would be its first exercise, on every host
at once.

This design says what the forge path needs, what is already fixed for it, and
what is genuinely unknown. It deliberately does not implement.

## What the bare-metal work already fixed FOR the forge

Not claimed as forge evidence — stated as shared plumbing, because the forge
pushes through the **same sshd** and the **same `tillandsias-receive`**:

| fix | why the forge needed it too |
|---|---|
| the mirror receives `TILLANDSIAS_MIRROR_SSHD` | otherwise sshd never starts, for any client |
| the mirror receives `TILLANDSIAS_MIRROR_ID` | otherwise `sshd-identity` dies at `require_mid` |
| the host-signer AppRole is bound to its policy | otherwise the mirror cannot obtain its own host certificate |
| `SetEnv` carries `VAULT_TOKEN_FILE` | otherwise the relay has no credential under ssh |
| `SetEnv` carries the six proxy variables | otherwise the relay cannot resolve github.com (enclave-only network) |

The sixth — two AppRole documents colliding at one mount target — was
conditional on the host-push half existing and is not a forge concern.

## What is UNKNOWN for the forge, and must be measured not assumed

1. **The sidecar path has never been exercised end to end.** `ssh-lane-sidecar.sh`
   mints a client cert on tmpfs, serves it over an agent socket volume, and
   re-signs every 20m against a 30m TTL. No push has ever traversed it. The
   bare-metal lane proves the *server* side and the *relay*; it proves nothing
   about the agent-socket client.
2. **The forge's `@cert-authority` wiring.** The gitconfig writer emits a
   `pushInsteadOf` to `ssh://git@git-<mirror-id>:2222` and a known_hosts line
   from the cached host CA. The bare-metal path needed `HostKeyAlias` because it
   connects to `127.0.0.1`; the forge connects to the enclave name directly and
   should not — that difference is **assumed, not measured**.
3. **Whether the sidecar's renewal actually renews.** A 30m TTL with a 20m loop
   has never run for 30m under observation.

## The finding this design turns on

**`TILLANDSIAS_PUSH_PRINCIPAL` is exported by `tillandsias-receive` and consumed
by nothing in production.** Measured: the only reader is
`scripts/test-mirror-receive-wrapper.sh`, a fixture that mints its own cert.

`tillandsias-receive` performs **no authorisation** on the principal — that is
sshd's `AuthorizedPrincipalsFile`, and that division is correct. But it means the
principal is extracted, exported, and discarded.

**So the distinct `til:host-push:<host>` principal currently buys nothing it was
created for.** It was made distinct so a host push and a forge push would be
distinguishable in the mirror's records and so revoking one would not revoke the
other. Revocation works (separate roles, separate policies). **Distinguishability
does not**: after authentication, nothing writes who pushed.

That is the gap this design proposes to close before the forge lane becomes
anyone's default — because the moment two client classes share a lane,
"who pushed this ref" stops being answerable by elimination.

## Proposed shape (for audit, not for implementation)

1. **Record the pusher.** The receive path already has
   `TILLANDSIAS_PUSH_PRINCIPAL`, `_SERIAL`, `_KEY_FP` and `_KEY_ID` in the
   environment. One line in the relay's log per ref transaction, naming the
   principal and serial, makes the audit trail real. No new plumbing.
2. **Dogfood the sidecar before flipping T11**, the way the host half was
   dogfooded: one forge, one push, the artifacts stated in the acceptance shape
   (cert accepted by the CA under `ssh -v`; the relay and pre-receive lines;
   `ls-remote` against **GitHub**, never the mirror).
3. **State the forge's regime** the way the three bare-metal regimes are stated,
   so a forge acceptance is comparable rather than assumed equivalent.

## What this design does NOT claim

- It does not cite lenovinha's or yoga's three legs as forge evidence. Different
  client, different transport to the same sshd, unexercised.
- It does not propose flipping T11. That waits on this audit **and** on a forge
  acceptance.
- It does not assert the sidecar is broken. It asserts it is **unmeasured**,
  which is a different claim and the reason for step 2.

## Amendments from the coordinator's audit (accepted)

Audited by macuahuitl-fedora, 2026-09-21: **accepted with amendments**.
Implementation may proceed on the amended shape once the audit event is on the
row. **The T11 flip still waits on a forge acceptance**, not merely on this
audit.

What the audit verified in code, so the design's claims are no longer only
mine: the principal finding holds (`tillandsias-receive.sh`, the `export TILLANDSIAS_PUSH_KEY_FP …` block, read only by
the wrapper fixture); `relay-refs.sh`’s `log_msg` and `pre-receive-hook.sh`’s own log helper already
log per transaction; the sidecar renews at 1200 s against 30 m; the
shared-plumbing table matches `60d8a8770`.

### A1 — unknown 2 is a PROBABLE DEFECT, not an assumption

> **STRUCK 2026-09-21 — do not implement.** Falsified on a live forge: the bare
> `@cert-authority git-<mid>` line verifies at port 2222 (`Host 'git-<mid>' is
> known and matches the ED25519-CERT host certificate`). `ssh-keygen -F` was the
> instrument on both sides and it is not the client. The writer stays as it is;
> 1341-mgry is closed obsoleted. The text below is kept as the record of the
> claim. See the Audit section's A1 for the real defect the same transcript
> found (1342-r4pv).


The forge's gitconfig writer emits `@cert-authority git-<mid> <ca>` and pushes
to `ssh://git@git-<mid>:2222/…` with `StrictHostKeyChecking=yes` and **no
`HostKeyAlias`**. OpenSSH looks a non-22 port up as `[host]:port`, so the bare
line cannot match.

**Measured twice, independently.** The coordinator measured it; this author
re-measured it on OpenSSH 10.2p1 rather than accept it:

| known_hosts line | lookup `[git-testmid]:2222` | lookup `git-testmid` |
|---|---|---|
| `@cert-authority git-testmid …` | **NO MATCH** | MATCHES |
| `@cert-authority [git-testmid]:2222 …` | MATCHES | — |

**The bare-metal lane works only because it passes `HostKeyAlias`, which is
looked up verbatim.** That is the difference the design called "assumed, not
measured" — and it is a defect, not a difference.

Expected first-push symptom: `Host key verification failed`.

Order: **measure first** from a forge with the lane on
(`ssh -v -p 2222 git@git-<mid> true`), then fix the writer — either spell the
line `@cert-authority [git-<mid>]:2222 …` or add `-o HostKeyAlias=git-<mid>` to
`core.sshCommand`. Both keep strict checking and no TOFU.

### A2 — arm 3 cannot run inside a forge

A forge has no DNS for github.com (`lib-common.sh`, the no-egress DNS note), so it cannot check
`ls-remote` equality against GitHub itself. A bare-metal peer or the coordinator
verifies equality **by the forge's pushed sha, handed over as a condition**. The
arm does not weaken; its verifier moves.

### A3 — the forge's race window is the mirror's upstream-sync lag

The relay REJECTs stale old-ids against upstream, and a forge **cannot refetch
GitHub** the way a bare-metal host does. So the dogfood runs **three plan-only
pushes at a measured trunk cadence and counts REJECTs**, and the sync cadence
must be **observable from inside a forge** (1338-tkfh) before any default flip.

### A4 — unknown 3 becomes an arm

A second push after **at least 30 minutes of sidecar uptime**, showing a
**different serial** in the relay's pusher line. That turns "has the renewal
ever renewed" from an open question into a measurement.

### A5 — where the pusher line goes

In `relay-refs.sh`'s log function, **per ref transaction**, carrying `KEY_ID`
(the mint-time identity) alongside principal and serial. It also serves an
existing attribution gap: tonight's `plan(unknown)` and `salvage/unknown`
(1337-3tk6).

### A6 — state the forge regime

A **Linux forge in a Silverblue enclave** first; the **WSL2 forge in yolanda's
enclave** second. Candidates, stated so a forge acceptance is comparable rather
than assumed equivalent — the same discipline the three bare-metal regimes use.

### A7 — the lane pushes work refs, it does not land them

**Forges cannot open PRs by design.** The lane carries a forge's work to a
`work/<order>` ref; landing remains a bare-metal or coordinator act.

### Not found

Nothing wrong in the authorisation division, nor in what the design declines to
claim.

## Exit condition

**Audited by the coordinator; an audit event on 1340-tzsx before any
implementation packet is claimed — including by the author.** Three acceptance
arms and two instruments of the bare-metal work were falsified by peers
measuring their own hosts; a design written alone for a client that has never
run deserves the same treatment before code follows it.

## Audit (macuahuitl-fedora, 2026-09-21)

**Outcome: ACCEPTED WITH AMENDMENTS. Implementation may proceed on the amended
shape below; the T11 flip (749-y8xx) still waits on a forge acceptance.**

Verified, by reading the code rather than the design: `TILLANDSIAS_PUSH_*` is
exported at `images/git/tillandsias-receive.sh` (its `export TILLANDSIAS_PUSH_KEY_FP TILLANDSIAS_PUSH_PRINCIPAL …` block) and read only by
`scripts/test-mirror-receive-wrapper.sh` (its `receive-env` record and the `hook-missing-serial` asserts — a fixture that
mints its own certificate and asserts what it minted); `relay-refs.sh` and
`pre-receive-hook.sh` (each through its `log` function) already write timestamped `[relay]`/`[pre-receive]`
lines to a log file, so the proposed pusher line has a home; the sidecar
(`images/git/ssh-lane-sidecar.sh`) renews every 1200 s against a 30 m TTL and
has no recorded 30-minute run; the shared-plumbing table matches the six fixes
at 60d8a8770.

**A1 — STRUCK (falsified on a live forge by lenovinha, 2026-09-21).** The
audit asserted that the forge's bare `@cert-authority git-<mid>` line would not
match a port-2222 lookup without `HostKeyAlias`, from `ssh-keygen -F` on this
host; lenovinha re-measured with the same instrument and agreed. On a live forge
(OpenSSH 10.2, lane on, writer untouched) the real client printed
`Host 'git-<mid>' is known and matches the ED25519-CERT host certificate` and
`Found CA key in /run/tillandsias/ssh-known_hosts:1`. `ssh-keygen -F` performs
one literal lookup; the client does not stop there. Two observers, one
instrument, no independence — the check has to be the client, not a model of
it. THE WRITER MUST NOT BE CHANGED; 1341-mgry is closed obsoleted. The same
transcript found the real forge-client defect the audit predicted in kind: the
sidecar's agent accumulates one identity per renewal until sshd's MaxAuthTries
runs out, so the lane dies about two hours after boot with "Too many
authentication failures" while a valid certificate sits on disk (1342-r4pv, p0,
fixed in PR #134; it blocks the T11 flip on its own).

**A2 — arm 3 cannot run inside a forge.** A forge has no DNS for github.com
(`images/default/lib-common.sh`, the comment beside its github-URL rewrite: "no DNS for github.com"), so "ls-remote against GitHub" is a
bare-metal peer's or the coordinator's arm: the forge hands its pushed sha as a
condition and the peer verifies equality on GitHub. The forge's own check is
against the mirror's `git://` read AFTER the relay confirms, with 1338-tkfh's
caveat that the mirror lags.

**A3 — the forge's race window is the mirror's sync lag, and it is unmeasured.**
The forge's base is the mirror's tip; the relay's staleness guard fetches
upstream and REJECTs a stale old-id; the forge cannot refetch from GitHub the
way yoga did (one loss in 82 s WITH a fresh fetch). So on a busy trunk (84–296 s
between moves tonight) forge pushes to linux-next fail whenever any host pushed
since the mirror last synced. The dogfood must include three plan-only pushes at
a measured trunk cadence and count the REJECTs, and the mirror's upstream-sync
cadence must become observable from inside a forge (1338-tkfh) before any
default flip.

**A4 — unknown 3 becomes an arm.** A second push after at least 30 minutes of
sidecar uptime; the serial in the relay's pusher line must differ from the first
push's. The log line and the renewal then verify each other.

**A5 — the pusher line.** Write it in `relay-refs.sh`'s log function per ref
transaction and include `KEY_ID` alongside principal and serial: the key id is
the mint-time identity (host name for `til:host-push`, mirror id for
`til:forge-push`), which is what attribution needs — tonight two forge
mechanisms landed as `plan(unknown)` and `salvage/unknown/` (1337-3tk6).

**A6 — regimes.** State the forge dogfood's regime as the bare-metal ones are
stated: a Linux forge inside a Silverblue dogfooder's enclave first (the
author's own), the WSL2 forge already running in yolanda's enclave second.
Candidates, not directives.

**A7 — consistent with the PR direction.** A forge cannot open PRs (its
`~/.config/gh` is a credential-less tmpfs by design); the lane's job is the
credential-free push of `work/<order>` refs, which a bare-metal host or the
coordinator then lands. The design should say so, so nobody reads the lane as a
landing path.

Not found: no defect in the finding the design turns on, in the division of
authorisation (sshd's `AuthorizedPrincipalsFile`), or in what the design refuses
to claim.
