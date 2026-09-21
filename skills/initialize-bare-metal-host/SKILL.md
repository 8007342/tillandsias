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

- `ok:bare-metal-host:<host>:enclave=up mirror=up router=up inference=up github=<seeded|not-seeded>` — exit 0
- `todo:initialize-bare-metal-host:<component>:<command>` — exit 1, and the command named is the fix

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

**Preconditions, both testable before you start.** The lane's six fixes must be
on trunk, and your own tree must contain them:

```bash
git merge-base --is-ancestor 88b0679d9 origin/linux-next && echo "fixes on trunk"
git rev-list --count HEAD..origin/linux-next        # 0, or merge first
```

If the first prints nothing, **stop** — the lane cannot come up, and every
failure below will be one of the six rather than anything about your host.

**The lane stays default-off.** Both variables are explicit on every command;
nothing here changes a default for anyone else.

### 6.1 — Bring the stack up with the lane on

```bash
TILLANDSIAS_HOST_PROJECT_ROOT=$HOME/claudia \
TILLANDSIAS_MIRROR_SSHD=1 \
TILLANDSIAS_HOST_PUSH_HOST=$(hostname -s) \
  tillandsias --bash <project> --debug
```

Exiting the shell leaves the stack up. `RC=124` from a `timeout` wrapper is the
interactive shell being cut off, not a failure.

**Done when** all three are true — check each, they fail independently:

```bash
podman exec tillandsias-git-<project> sh -c \
  'echo "SSHD=${TILLANDSIAS_MIRROR_SSHD:-unset} MID=${TILLANDSIAS_MIRROR_ID:-unset} TOKENFILE=${TILLANDSIAS_VAULT_TOKEN_FILE:-unset}"; pgrep -a sshd || echo "sshd NOT running"'
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
| (b) | `work/<order>` |
| (c) | another side branch — a `salvage/<host>/<date>-<slug>` ref |

**Step 0, before any leg: find out which credential path your host actually
has.** The arm being proven is *"this host's configured credential path is
proven unread"* — and the instrument for that differs by host. Measured by yoga:
on their host git never reads the keyring at all, so a "keyring PID unchanged"
arm cannot fail there even when a credential IS read. An arm that cannot fail is
not an arm.

```bash
git config --show-origin --get-regexp 'credential.*helper'
```

**Use `--get-regexp`, not `--get-all credential.helper`.** The latter misses
URL-scoped keys such as `credential.https://github.com.helper`, and on lenovinha
it returns *empty* while a helper is configured — a false "no credential path
here" that was written into this session's notes before it was caught.

Then pick the instrument that matches what you found:

**Instrument A — a libsecret/keyring helper** (e.g. `!gh auth git-credential`):

```bash
pgrep -f 'gnome-keyring-daemon.*components=secrets' | head -1   # before AND after
grep -ac 'git-credential' <transcript>                          # expect 0
```

Name the daemon **by component**: there are two on a Silverblue host,
`--daemonize --login` and `--start --foreground --components=secrets`. Secret
Service is the second, and `ps -C gnome-keyring-d | head -1` can return either.

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

### The acceptance criterion, restated

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

**(2) No host-side GitHub credential path was read** — instrument per §Step 0
(libsecret keyring PID; file store moved aside; or, where no helper exists at
all, say so and claim less).

**(3) `ls-remote` equality and no TOFU** — the ref on origin equals your local
head at push time, and the push ran with `StrictHostKeyChecking=yes` against the
`@cert-authority` file under `HostKeyAlias`.

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
