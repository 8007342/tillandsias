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

## v1 limits

**The ssh push lane is not up. Pushes still take the keyring path.** Work is in
flight on 1310-5e6g; the mirror's host-signer identity is not yet wired, so the
Vault signer answers 403 and the mirror's sshd does not start. v2 of this skill
adds the lane when it works, and the fleet-wide instruction waits for a host
push that has travelled host → mirror → GitHub.

`tillandsias --github-status` does not exist yet either — it is a 1288-5qpn
deliverable. Step 2's checker reports the `github=` field in its place.

## Repairs

Append an entry for every repair actually performed on a real host. Each entry
carries all five fields; `scripts/check-bare-metal-host-initialized.sh`'s
fixture refuses an entry missing any of them. This section is how the skill
evolves — it is a log of what actually broke, not of what might.

- date: 2026-09-20 | host: lenovinha-silverblue | symptom: the whole enclave absent; `tillandsias-vault` had been `Exited (143)` for three days and nobody noticed | command: `podman ps -a --format '{{.Names}}\t{{.Status}}'` | fix: `tillandsias --ensure-enclave` — it is idempotent and re-provisions policies, so it is safe to run on a partially-up host
- date: 2026-09-20 | host: lenovinha-silverblue | symptom: every relay push failing `fatal: Authentication failed`, mirror otherwise healthy | command: `podman exec tillandsias-git-<project> sh -c 'curl -s -o /dev/null -w "%{http_code}" --cacert /etc/tillandsias/ca.crt -H "X-Vault-Token: $(cat /tmp/tillandsias-vault-token)" https://vault:8200/v1/secret/data/github/token'` (200 means present, 403 means the mirror cannot read it, 404 means unseeded) | fix: the operator seeds it with `tillandsias --github-login --with-token`; no agent may do this
- date: 2026-09-20 | host: lenovinha-silverblue | symptom: lane launch exits non-zero with "REFUSING to launch tillandsias-<project>-forge-maintenance: the name is held by a RUNNING container" | command: `podman ps --format '{{.Names}}' \| grep forge-maintenance` | fix: a previous lane of your own left it running; remove it deliberately (`podman rm -f <name>`) only after confirming no sibling lane owns it — order 494 refuses automatically because the workspace may hold unpushed work
