---
name: initialize-bare-metal-host
description: Bring up, rebuild and troubleshoot THIS bare-metal host's own tillandsias enclave and per-project git mirror, idempotently. Does not seed, prompt for, or copy a GitHub token. Referenced by join-the-fleet as its substrate step.
---

# Initialize Bare Metal Host

Brings up — and rebuilds, and troubleshoots — **this host's own** enclave and
per-project git mirror. Every command is ensure-shaped, so running the skill
twice is safe and the second run changes nothing.

**Scope: bring the stack up.** Not "credential-free pushes". See
[v1 limits](#v1-limits).

**This skill never seeds, prompts for, or copies a GitHub token.** Seeding is
the operator's own act. Every host that seeds ends holding a copy of the same
credential, so revoking one revokes all — that is the operator's per-host
decision, not a step any recipe performs for them.

---

## 1 — Bring the stack up

```bash
tillandsias --ensure-enclave                                   # vault, proxy
TILLANDSIAS_HOST_PROJECT_ROOT=$HOME/claudia \
  tillandsias --bash <project>                                 # mirror, router, inference
```

`--ensure-enclave` is the documented restore path after a reboot or a stopped
proxy. The second command launches a lane, which brings up the **per-project**
mirror `tillandsias-git-<project>` (order 659-8faj: mirrors do not share an
alias). It opens an interactive shell; exiting it leaves the stack running.

`TILLANDSIAS_HOST_PROJECT_ROOT` defaults to `$HOME/src`. Set it to the parent of
your checkout.

**Work refs go through this mirror like any other ref** (1317-9ugn; methodology
`work_ref_lane`, 1315-4a7j). A push to `work/<order>` needs no gate stamp and
no trunk merge: the pre-push hook's deciders run and warn, nothing refuses, and
the mirror's relay carries the ref upstream on the same sweep as a platform
branch. Only `main` and the platform branches carry the gate. So a host whose
mirror is up can push its work ungated as often as it likes, and "the mirror
relays `fatal:` for a work ref" is the same benign sweep noise §5 describes.

## 2 — Verify, without repairing

```bash
scripts/check-bare-metal-host-initialized.sh
```

Non-mutating: it starts nothing and writes nothing.

- `ok:bare-metal-host:<host>:enclave=up mirror=up router=up inference=up github=<seeded|not-seeded> lane=<off|wired:<principal>|unwired:<reason>>` — exit 0
- `todo:initialize-bare-metal-host:<component>:<command>` — exit 1, and the command named is the fix

**The `lane=` field is a READ, not a proof.** It says what can be seen without
minting anything: `off` when the lane flag is not set in the mirror,
`wired:<principal>` when sshd is up and the mirror authorises a host principal,
`unwired:<reason>` otherwise. A `wired:` reading does NOT mean the lane works —
only the three legs of §6 show that. The field exists because this verdict was
otherwise silent about the lane, and a green that is true and ADJACENT gets read
as coverage.

**On a FROM-ZERO host the `lane=` field cannot be read at all, and that is
structural rather than a fault.** `lane=` is emitted only on the `ok:` line; a
host with no mirror yet exits earlier with
`todo:initialize-bare-metal-host:mirror:<command>` and rc=1, and never reaches
it. The mirror is PER-PROJECT and comes up at lane launch (§1's second command),
so before that bring-up there is no mirror to ask about a lane.

**So ask for `lane=` AFTER §6.1's bring-up, never before it.** A from-zero
operator who looks for the field first will read its absence as the lane being
broken, when what it means is that the question has not become askable yet.
Measured on pirria 2026-09-21 in the stable-channel smoke, from a host reset to
zero with `podman system reset --force`.

**Why a separate read exists.** The step-1 commands are ensure-shaped, so
running them is the remedy for almost everything. That is exactly why "did it
work?" must not be answered by running the remedy again — that cannot tell a
healthy host from one repaired on every check and broken in between.

## 3 — The GitHub credential is the operator's

`github=not-seeded` is a normal, correct state. **Stop there.** The host is up;
it simply has no credential, and no agent should seed one.

The operator seeds it themselves, on their own host:

```
tillandsias --github-login --with-token     # reads the token from STDIN
```

`--with-token` runs **no device flow**, so it cannot trigger the multi-host
token eviction that order 1025-a896 forbids. Never run `gh auth login` or
`gh auth refresh`.

## 4 — Restart discipline

While **each host owns its own mirror**, a host may restart its own mirror
freely — no coordination needed. That ends the day a mirror is shared
(1290-5833), which is when a broken mirror must refuse to advertise itself
(1310-rec6) instead of silently stranding other hosts' work.

```bash
podman restart tillandsias-git-<project>
```

A restart triggers the mirror's startup relay sweep, which pushes any refs it
holds upstream.

## 5 — Troubleshooting

### The relay prints `fatal:` dozens of times and everything is fine

**Measured on lenovinha 2026-09-20: a fully successful sweep emitted 59
`fatal: the remote end hung up unexpectedly` lines beside 23
`Startup retry-push OK`.** They were retries that succeeded. Before the
credential existed the same sweep printed `fatal: Authentication failed` — a
**real** failure in the **same shape**.

So do not read `fatal:` in the relay log as failure. **Discriminate by
outcome**, never by the log:

```bash
podman exec tillandsias-git-<project> \
  git -C /srv/git/<project> for-each-ref --format='%(refname:short)' refs/heads | sort > /tmp/m.txt
git for-each-ref --format='%(refname:lstrip=3)' refs/remotes/origin | sort > /tmp/o.txt
comm -23 /tmp/m.txt /tmp/o.txt        # refs the mirror holds that origin lacks; empty == relayed
```

Fixing the noise is 1310-rec6's job; until then this command is the answer.

### A container name is held by a running container

The launcher **refuses** rather than replacing it (order 494, leak-not-destroy):
a concurrent lane may own it and its workspace may hold unpushed work. Stop that
lane, or clear the container deliberately if you know it is yours.

### The ssh push lane does not come up

Expected in v1 — see below. `sshd NOT running` inside the mirror is the current
state, not a fault you can fix here.

## 6 — The credential-free push lane (Silverblue dogfooders)

**Who this is for.** The Silverblue hosts are the dogfooders — lenovinha, yoga,
pirria. Windows and macOS likely never need it.

**FIRST, BEFORE ANYTHING ELSE — two preconditions, in this order.**

**(i) The fixes must be on trunk, and in your tree.** The client half —
`TILLANDSIAS_HOST_PUSH_HOST` and the `til:host-push:` principal — arrives only
with the lane fixes. Measured by pirria: `TILLANDSIAS_MIRROR_SSHD` is consumed
on trunk today, but the host-push half appeared nowhere outside `plan/` before
they landed. A host that starts early fails in a way that reads as a HOST
problem and is not one.

```bash
git merge-base --is-ancestor 88b0679d9 origin/linux-next && echo "fixes on trunk"
git merge-base --is-ancestor 88b0679d9 HEAD && echo "and in my tree"
git rev-list --count HEAD..origin/linux-next        # 0, or merge first
```

**(ii) THE BINARY YOU RUN MUST CARRY THEM — this is not the same question.**
Found by pirria before running: `images/git/*` (including `sshd-identity.sh`) is
**embedded in the tillandsias binary at compile time** and materialised
unconditionally. So a host whose binary predates the fixes rebuilds its mirror
**without** them, and the relay fails as `Could not resolve host: github.com` —
a network error on the wrong host, for a reason that is not network.

Release **v56.9.21.1 was cut ~11 h before the fixes landed**, so every host on
that installed release is in this state until the next daily.

Two regimes work; **say in your report which one you used**:

- **Install from a checkout at or above the fixes** — `./build.sh --install`
  (the install target with the autoincrement; never `SKIP_VERSION_BUMP`), then
  confirm `tillandsias --version` descends from the fixes.
- **Run the checkout's binary directly** — `./target/release/tillandsias`,
  leaving the installed one alone.

**What lenovinha did, stated so the three regimes are comparable:** the second.
This host's acceptance was run entirely with `./target/release/tillandsias`
(v56.9.21.1 built from a tree descending from the fixes), while the *installed*
binary on `PATH` was **v56.9.12.2** the whole time and was never used. `./build.sh
--install` was never run here. So lenovinha's legs do not evidence the install
path — only the checkout-binary path.

**Confirm the BINARY carries the fix. `tillandsias --version` cannot tell you.**
It prints a version and no git sha, so no ancestry check is possible against it
— a version string can match while the embedded assets do not, which is exactly
the trap. Grep the binary instead, with two controls so the result is readable:

```bash
BIN=<the binary you will run>                 # installed path, or ./target/release/tillandsias
strings -a "$BIN" | grep -c RELAY_HTTP_PROXY        # MARKER  — expect >= 1
strings -a "$BIN" | grep -c TILLANDSIAS_RECEIVE_ROOT # CONTROL — expect >= 1 on ANY build
```

- **The marker is the fix's own text.** `RELAY_HTTP_PROXY` is absent at
  `88b0679d9^` and present at `88b0679d9`, so finding it means that commit's
  content is embedded. A *load-bearing* name is chosen deliberately over a
  comment: a comment can be reworded while the fix remains, which would fail the
  check for no reason; if this variable disappears, the fix really has.
- **The control proves a 0 is meaningful.** If the marker reads 0 and the
  control also reads 0, you cannot read that binary at all and the answer is
  unknown, not "absent".

Measured on this host, both binaries present at once:

| string | checkout build v56.9.21.1 | installed v56.9.12.2 |
|---|---|---|
| `RELAY_HTTP_PROXY` (marker) | 2 | **0** |
| `TILLANDSIAS_RECEIVE_ROOT` (control) | 3 | 3 |

**If you took the install route: `./build.sh --install` BUMPS `VERSION` in your
tree.** Do not commit that on a work ref — a VERSION bump is a cut's own commit
(702-eusw). Leave it, or restore it, but do not carry it into your PR.

**The lane stays default-off.** Both variables are explicit on every command
below; nothing here changes a default for anyone else.

### 6.1 — Bring the stack up with the lane on

```bash
TILLANDSIAS_HOST_PROJECT_ROOT=$HOME/claudia \
TILLANDSIAS_MIRROR_SSHD=1 \
TILLANDSIAS_HOST_PUSH_HOST=$(hostname -s) \
  tillandsias --bash <project> --debug
```

Exiting the shell leaves the stack up. `RC=124` from a `timeout` wrapper is the
interactive shell being cut off, not a failure.

**BUT DO NOT READ rc AS THE ANSWER.** Measured by yoga: `tillandsias --bash
<name> --debug` on an UNRESOLVABLE project prints `Error: Project not found`
and **exits 0** — so a real failure reads as CLEANER than the timeout. Only the
three checks below distinguish them, which is why they are three independent
reads and not a convenience.

**Done when** all three are true — check each, they fail independently:

```bash
podman exec tillandsias-git-<project> sh -c \
  'echo "SSHD=${TILLANDSIAS_MIRROR_SSHD:-unset} MID=${TILLANDSIAS_MIRROR_ID:-unset} TOKENFILE=${TILLANDSIAS_VAULT_TOKEN_FILE:-unset}"; p=$(cat /tmp/tillandsias-sshd/sshd.pid 2>/dev/null); if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo "sshd running pid=$p"; else echo "sshd NOT running"; fi'
podman ps --format '{{.Names}}\t{{.Ports}}' | grep git-      # expect 127.0.0.1:2223->2222/tcp
ls -l ~/.config/tillandsias/host-push/                       # expect <host>.approle.json, mode 0600
```

`sshd NOT running` with all three variables set means the signer agent has no
sink — look at `/tmp/tillandsias-sshd/sshd.err` **inside the container**, not at
`podman logs` (two producers write "Connection from" into different files; the
container log's are the git daemon's healthcheck, every 2 seconds).

### 6.2 — Mint this host's push certificate

```bash
scripts/tillandsias-host-push-cert.sh
```

**Done when** it prints one line:

```
ok:host-push-cert:<…>/<host>.ed25519-cert.pub known_hosts=<…>/known_hosts alias=git-<mirror-id>
```

`known_hosts=ABSENT:<path>` means the host-CA cache is missing — the certificate
is usable but host verification is not wired, and §6.3 will fail at
verification rather than at authentication. Any `fail:` line installs nothing.

Verify what you were handed rather than trusting the verdict:

```bash
ssh-keygen -L -f ~/.config/tillandsias/host-push/$(hostname -s).ed25519-cert.pub
```

Expect `user certificate`; `Principals:` carrying **exactly one** line,
`til:host-push:<host>`; `force-command /usr/local/bin/tillandsias-receive`;
`source-address` the **enclave subnet** (10.0.42.0/24, NOT 127.0.0.1/32 — a host
arrives through the rootless published port and sshd sees an enclave peer);
`Extensions: (none)`; and ~30 minutes of validity.

**The TTL is real.** A cert minted more than half an hour ago fails
`Permission denied (publickey)`. Re-run the mint; that is the design, not a
fault.

### 6.3 — Push through the lane

```bash
KH=~/.config/tillandsias/host-push/known_hosts
K=~/.config/tillandsias/host-push/$(hostname -s).ed25519
ALIAS=$(awk '/^@cert-authority/{print $2; exit}' "$KH")

GIT_SSH_COMMAND="ssh -o UserKnownHostsFile=$KH -o StrictHostKeyChecking=yes \
  -o HostKeyAlias=$ALIAS -o BatchMode=yes -o IdentitiesOnly=yes -i $K -p 2223" \
  git push "ssh://git@127.0.0.1/srv/git/<project>" HEAD:refs/heads/<ref>
```

**`HostKeyAlias` is required, and `StrictHostKeyChecking=yes` is not optional.**
The mirror's host certificate is valid for the principal `git-<mirror-id>`, and
ssh matches a host certificate against the name you ASKED FOR — connecting to
`127.0.0.1` by address can never match it. `-o HostName=…` does not help; it
makes ssh key the known_hosts lookup on the address too. Never use
`StrictHostKeyChecking=no`: it TOFUs a key that changes on every mirror rebuild,
and the next connection fails `REMOTE HOST IDENTIFICATION HAS CHANGED`.

**Done when** the remote says both lines:

```
remote: [relay] Atomic push to https://github.com/<owner>/<repo>.git succeeded
remote: [pre-receive] Relay verified: upstream durably accepted the ref transaction
```

A `[pre-receive] Push rejected: configured upstream did not durably accept the
ref transaction` means the relay failed and **refused rather than stranding your
ref** — that is correct behaviour. Read the `[relay]` line above it for the
cause; it names the layer.

### 6.4 — The three acceptance legs, and their artifacts

Run all three the same way. One leg taken differently is not a third
measurement.

| leg | ref |
|---|---|
| (a) | `linux-next` — a plan-only commit cherry-picked onto a clean base off `origin/linux-next` |

**Leg (a) needs a fetch, and expects to lose a race.** Run `git fetch origin`
(an anonymous https read — confirm with `GIT_TRACE=1` that no helper runs)
**immediately** before the plan-only push, then rebase and push at once. The
hook keys the cheap lane on the remote tip being a LOCAL OBJECT, and **a push
through the mirror fetches nothing** — the relay carries refs up and brings
nothing down — so a clone that has not fetched since trunk moved is told
`plan-only lane: not applicable — remote base <sha> is not present locally`.
On a busy trunk expect to lose once: yoga saw an 82-second push lose to a
plan-only move and the relay answer `[pre-receive] REJECT: stale old object ID
does not match current ref`. **That is the staleness guard working, not a lane
fault.** Fetch, rebase, push again.
| (b) | `work/<order>` |
| (c) | another side branch — a `salvage/<host>/<date>-<slug>` ref |

**Step 0, before any leg: find out which credential path your host actually
has.** The arm being proven is *"this host's configured credential path is
proven unread"* — and the instrument for that differs by host. Measured by yoga:
on their host git never reads the keyring at all, so a "keyring PID unchanged"
arm cannot fail there even when a credential IS read. An arm that cannot fail is
not an arm.

**Two instruments, and the SECOND decides.** `--get-regexp` says what is
*configured*; `git credential fill` under `GIT_TRACE=1` says what actually
*runs*. A host can differ between them.

```bash
git config --show-origin --get-regexp 'credential.*helper'        # CONFIGURED
printf 'protocol=https\nhost=github.com\n\n' | GIT_TRACE=1 git credential fill   # RUNS
```

**Use `--get-regexp`, not `--get-all credential.helper`.** The latter misses
URL-scoped keys such as `credential.https://github.com.helper`, and on lenovinha
it returns *empty* while a helper is configured — a false "no credential path
here" that reached this session's notes before it was caught.

**Yoga's host is the cautionary example, and it corrects an earlier version of
this page.** This section once said "on yoga git never reads the keyring at
all". That claim was derived with `--get-all` — the instrument this very section
warns against — applied to themselves. `--get-regexp` shows a keyring helper
configured GLOBALLY there (`credential.https://github.com.helper` →
`gh auth git-credential`). The conclusion survives, but for a narrower reason
than stated: a **repo-scope empty** `credential.helper` entry RESETS the
inherited list before the file store is added, and the trace shows exactly one
`run_command` — `credential-store --file=.git/.gh-credentials` — and nothing
else. **Delete that one empty line and the keyring path goes live.** So: a host
with a keyring helper configured, correctly concluded unused, right for a reason
one config edit away from false. Record which instrument you used and what it
showed.

Then pick the instrument that matches what actually RUNS:

**Instrument A — a libsecret/keyring helper** (e.g. `!gh auth git-credential`):

```bash
for p in $(pgrep -x gnome-keyring-d); do
  tr '\0' ' ' < /proc/$p/cmdline | grep -q 'components=secrets' && echo "$p"
done                                            # before AND after| head -1   # before AND after
grep -ac 'git-credential' <transcript>                          # expect 0
```

Name the daemon **by component**: there are two on a Silverblue host,
`--daemonize --login` and `--start --foreground --components=secrets`. Secret
Service is the second, and `ps -C gnome-keyring-d | head -1` can return either.

**Do NOT use `pgrep -f 'gnome-keyring-daemon.*components=secrets'`.** Run from a
tool call, the enclosing `bash -c` carries that pattern in *its own* command
line, so `pgrep -f` matches the agent's shell as well as the daemon — the
self-matching-instrument shape of 1287-myx8. Measured here: that pattern
returned **two** pids, the daemon and the shell. `head -1` happened to return the
daemon only because the boot-time daemon has the lower pid; had the daemon
restarted and taken a higher one, the "before AND after" compare would have been
comparing *shell* pids and would have read a changed shell as a changed daemon.

A bracket (`gnome-keyring-daemo[n]`) does **not** reliably fix it either — if the
unbracketed pattern appears anywhere else in the same command line, it
self-matches again, which is exactly what happened when this was tested. `-x`
matches the executable name only and never the pattern, so it cannot self-match.

**Instrument B — a file store** (e.g. `store --file=.git/.gh-credentials`):

```bash
mv <store-file> <store-file>.acceptance-aside      # before the three legs
… run the legs …
mv <store-file>.acceptance-aside <store-file>      # restore immediately after
grep -ac 'git-credential' <transcript>             # expect 0
```

A push that succeeds while the credential is **absent from disk** proves the
lane needs none. Restore the file as soon as the legs are done — leaving it
aside breaks every ordinary push on that host.

**Either way, leave the helper CONFIGURED.** Zero invocations then means it
demonstrably did not fire, which is a stronger claim than it being absent.

**If no helper is configured at all**, say so and claim less: the legs show the
lane works, but they cannot show a credential path went unread, because the host
had none to read.

**WHY "zero helper invocations" IS NOT ON ITS OWN AN ARM.** Found by pirria: a
URL-scoped helper — `credential.https://github.com.helper`, which lenovinha and
pirria both carry — is *never consulted for an `ssh://` URL*. Zero invocations
is therefore guaranteed by SCOPE and says nothing about the lane. It is worth
recording, but it is not evidence. The three arms below are.

### The acceptance criterion

**An arm must name what the lane MADE TRUE, not what it failed to do.**

This is yoga's rule, and it was earned: three arms of an earlier template were
found incapable of failing, each asserting a *local absence* that was already
true for a reason unrelated to the lane — a keyring PID unchanged on a host
whose git never reads the keyring; zero helper invocations on any ssh push,
because the helper is scoped to `https://github.com`. An absence proves nothing
unless something could have made it present.

The arms below each assert a **positive fact the lane had to produce**. Each can
fail. If you find yourself recording that nothing happened, ask what would have
had to happen for the arm to fail — and if the answer is "nothing could have",
it is not an arm.


**(1) The push authenticated by the HOST CERT over ssh.** Add `-v` to
`GIT_SSH_COMMAND` and keep the transcript:

```
debug1: Server accepts key: …/<host>.ed25519 ED25519-CERT SHA256:… explicit
Authenticated to 127.0.0.1 ([127.0.0.1]:2223) using "publickey".
remote: [relay] Atomic push to https://github.com/<owner>/<repo>.git succeeded
remote: [pre-receive] Relay verified: upstream durably accepted the ref transaction
```

ssh offers the bare key *and* the certificate; the line that matters says
**ED25519-CERT** was the one accepted. A plain `ED25519` acceptance would mean
an `authorized_keys` path, not the CA — and this mirror has
`AuthorizedKeysFile none`, so it should be impossible.

**(2) The push succeeded while the host's GitHub credential was provably
unavailable.** Stated positively, because that is the fact the lane produced.
The instrument is the one that can make it unavailable on your host:

- **File store** — move the store file aside for the three legs, restore
  immediately after. A push that succeeds with the credential absent from disk
  is a positive result: the lane needed none.
- **libsecret/keyring** — *this arm is WEAKER here and the procedure says so.*
  The honest version would lock the collection, but on this fleet a Secret
  Service read can abort gnome-keyring 50 (1265-8qr6) and cost the operator an
  unlock, so we do not. What remains is the keyring daemon's PID unchanged
  across the push, named by component — an absence, recorded as corroboration
  and NOT claimed as proof. Say which you have.
- **No helper configured** — claim less: the legs show the lane works, but not
  that a credential path went unread, because there was none.

all, say so and claim less).

**(3) `ls-remote` equality and no TOFU** — the ref on origin equals your local
head at push time, and the push ran with `StrictHostKeyChecking=yes` against the
`@cert-authority` file under `HostKeyAlias`.

**Check equality against GITHUB, never against the mirror.** The mirror REFUSES
`ls-remote` by design — its force-command is receive-pack only, so it answers
`fail:tillandsias-receive:not-receive-pack`. And do not silence that refusal:
yoga nearly filed "the mirror has no linux-next ref" because a `2>/dev/null`
turned a principled refusal into empty output, which is indistinguishable from
an absent ref. (The same suppression cost this host ten push attempts mislabelled
as races earlier in the same session.)

```bash
git ls-remote origin refs/heads/<ref>
```

If trunk moves before you report leg (a), give **ancestry** rather than a stale
equality: `git merge-base --is-ancestor <your-sha> origin/linux-next`.

### 6.5 — What this proves, and what it does not

It proves the lane for **your host**, with the lane **default-off**. It proves
nothing about the **forge** client, which pushes through the same sshd and the
same `tillandsias-receive` but has not been exercised. Do not cite another
host's legs as evidence for your own, and do not cite any of them as evidence
for the forge.

## Limits

**The ssh push lane works, on a host that has the six fixes** (§6). It stays
**default-off**: nothing comes up unless `TILLANDSIAS_MIRROR_SSHD=1` and
`TILLANDSIAS_HOST_PUSH_HOST` are both given explicitly. A host without them
behaves exactly as it did before, and pushes take the keyring path.

**`tillandsias --github-status` still does not exist** — it is a 1288-5qpn
deliverable. §2's checker reports the `github=` field in its place.

**Which binary.** `tillandsias` on `PATH` may be an older install than your
checkout builds. The installed app **refuses** to rebuild the enclave from its
own older embedded assets and says so, which is correct — but this skill's
commands assume whichever binary matches the tree you are testing. Use
`./target/release/tillandsias` when working from a checkout, and suspect a stale
binary FIRST when behaviour does not match the source:

```bash
strings target/release/tillandsias | grep -c '<a-symbol-your-change-added>'
```

**Before you say "filed", "closed" or "landed".** A host whose pushes are
silently not arriving is indistinguishable from a quiet one until someone runs
status on the other end:

```bash
git ls-remote origin refs/heads/linux-next
git rev-list --count origin/linux-next..HEAD     # 0, or it never left
```

**A merge is part of the read.** `tillandsias-plan` folds from the WORKTREE, so
a stale fold answers confidently and wrongly — a row read `ready` here while its
claim sat on trunk 26 commits ahead. Check before trusting any status:

```bash
git rev-list --count HEAD..origin/linux-next     # 0, or merge first
```

## Repairs

Append an entry for every repair actually performed on a real host. Each entry
carries all five fields; `scripts/check-bare-metal-host-initialized.sh`'s
fixture refuses an entry missing any of them. This section is how the skill
evolves — it is a log of what actually broke, not of what might.

- date: 2026-09-20 | host: lenovinha-silverblue | symptom: the whole enclave absent; `tillandsias-vault` had been `Exited (143)` for three days and nobody noticed | command: `podman ps -a --format '{{.Names}}\t{{.Status}}'` | fix: `tillandsias --ensure-enclave` — it is idempotent and re-provisions policies, so it is safe to run on a partially-up host
- date: 2026-09-20 | host: lenovinha-silverblue | symptom: every relay push failing `fatal: Authentication failed`, mirror otherwise healthy | command: `podman exec tillandsias-git-<project> sh -c 'curl -s -o /dev/null -w "%{http_code}" --cacert /etc/tillandsias/ca.crt -H "X-Vault-Token: $(cat /tmp/tillandsias-vault-token)" https://vault:8200/v1/secret/data/github/token'` (200 means present, 403 means the mirror cannot read it, 404 means unseeded) | fix: the operator seeds it with `tillandsias --github-login --with-token`; no agent may do this
- date: 2026-09-20 | host: lenovinha-silverblue | symptom: lane launch exits non-zero with "REFUSING to launch tillandsias-<project>-forge-maintenance: the name is held by a RUNNING container" | command: `podman ps --format '{{.Names}}' \| grep forge-maintenance` | fix: a previous lane of your own left it running; remove it deliberately (`podman rm -f <name>`) only after confirming no sibling lane owns it — order 494 refuses automatically because the workspace may hold unpushed work
- date: 2026-09-20 | host: lenovinha-silverblue | symptom: this skill's own commands fail because `tillandsias` on PATH is an older install than the checkout builds; the app refuses with "Continuing would rebuild the enclave's images from this older app's embedded assets" | command: `tillandsias --version` against `./target/release/tillandsias --version` | fix: use the checkout's binary when testing a checkout; the refusal is correct and is protecting you from a silent runtime downgrade
- date: 2026-09-20 | host: lenovinha-silverblue | symptom: a code change appears to have no effect and you begin diagnosing a logic bug that does not exist | command: `strings target/release/<bin> \| grep -c '<symbol-your-change-added>'` | fix: rebuild; a stale release binary cost four diagnostic steps here, and this check settles it in ten seconds — run it FIRST
- date: 2026-09-21 | host: lenovinha-silverblue | symptom: sshd is running and the cert is valid, but every push through the lane is rejected with "[relay] Vault Agent token is expired or unavailable" or "Could not resolve host: github.com", while the same commands run by hand inside the container succeed | command: `podman exec <mirror> sh -c 'env -i PATH=/usr/local/bin:/usr/bin:/bin sh -c "vault-cli lookup-self >/dev/null 2>&1; echo rc=\$?"'` — rc=2 reproduces it | fix: sshd hands a forced command ONLY what SetEnv passes; the container's environment is not inherited. The rendered sshd_config must carry VAULT_TOKEN_FILE and the six proxy variables. Over the anonymous git:// daemon the relay inherits the entrypoint's env, which is why that path works and this one did not
