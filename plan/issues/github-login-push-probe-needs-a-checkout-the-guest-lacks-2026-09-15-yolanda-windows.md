# `--github-login` cannot succeed on a host whose guest has no checkout

**Status: root cause ESTABLISHED by controlled experiment (§11).** One variable
— the process working directory — separates three identical failures from one
success. The tray lane remains broken; only this host's symptom is relieved.

The 759-vceg push-authorization probe resolves its target repository from the
**process's current working directory**. The tray always launches the login
inside the guest, where the working directory is `/root` and — after the
`~/src` removal — there is no git checkout anywhere in the VM. The probe
therefore takes its `None` arm on every attempt, refuses, and returns without
writing the token to Vault.

**The guard is correct. Its precondition is unsatisfiable in the lane where it
runs.** That is the defect, and it is a design gap rather than a Windows bug —
Windows and macOS tray hosts merely hit it first, because their login always
executes in the guest.

trace: spec:remote-projects, spec:tillandsias-vault, order 759-vceg
host: yolanda-windows (Windows 11, WSL guest distro `tillandsias`), v56.9.12.2

---

## 1. Operator-visible symptom

GitHub Login accepts a token, then throws immediately; remote projects are
never listed. The tray log shows the sign-in state resolving straight back to
`signed-out` a few seconds after each attempt, and `cloud-projects: fetch
unconfirmed` on every poll since 2026-09-12:

```
20:55:14  tray menu click menu_id=github-login action=GithubLogin
20:55:19  github sign-in state resolved from="signing-in" to="signed-out"
20:55:51  WARN cloud-projects: fetch unconfirmed; keeping previous list
```

## 2. The enumeration error is a truthful downstream report, not the defect

`tillandsias-headless --list-cloud-projects --debug` in the guest:

```
[tillandsias] gh: run_git_image_shell FAILED status=exit status: 2
  stderr="vault-cli: HTTP error reading secret/data/github/token:
  curl: (22) The requested URL returned error: 404"
```

404 = absent. Confirmed directly against Vault with the root token: `vault kv
list secret/` returns **only** `mirror-identity/`. There is no `secret/github/`
path at all. The reader is behaving correctly and reporting an absent secret.

## 3. Where it actually fails — `run_provider_login`, the 759-vceg probe block

```rust
match read_host_project_origin_url(Path::new("."))
    .as_deref()
    .and_then(github_owner_repo_from_origin)
```

`Path::new(".")` is the login process's CWD. The `None` arm returns, verbatim:

```
no GitHub upstream is configured for this checkout, so push permission cannot
be verified against a repository.

Nothing was written to Vault. Seeding on authentication alone is the state
order 759-vceg exists to prevent...

Run this login from a checkout whose `origin` points at the target repository,
or set TILLANDSIAS_PROJECT_REMOTE_URL, then try again (order 759-vceg).
```

"Nothing was written to Vault" is the literal text, and it matches the measured
state exactly.

## 4. Measured in the guest, not inferred from the host

```
find / -maxdepth 6 -name .git -type d   ->  (no output: not one checkout in the VM)
ls -la /home/forge/src                  ->  empty
bash -lc pwd                            ->  /root
```

So the `None` arm is guaranteed on every login attempt on this host, regardless
of which token is pasted.

## 4b. This guest build has no `git` either, so the precondition is doubly unsatisfiable

**Provenance, because this is the perishable half of the finding.** Measured
2026-09-15 on WSL distro `tillandsias`, `Fedora Linux 44 (Container Image)`,
guest binary `Tillandsias v56.9.12.2`. It is a property of THIS image build, not
a settled property of "the guest" — if a later image gains `git`, this section
is out of date and must not be read as still true.

```
rpm -q git  ->  package git is not installed
rpm -q gh   ->  package gh is not installed
```

(`rpm -q` rather than `command -v`, because it answers about the installed
package set rather than about one shell's PATH.)

Both ship only in the container images, not in the bare VM rootfs. So on this
build the tray lane cannot satisfy the probe's precondition **and has no tool
with which to create one** — an operator following the refusal's first remedy
("run this login from a checkout") cannot produce a checkout in the guest,
because there is nothing in there to clone one with.

**The durable half is that the resolver has a documented no-git path.**
`read_host_project_origin_url`'s `Command::new("git")` fails to spawn and it
falls through to `parse_gitdir_origin_url`, documented as the reader "used when
no `git` binary is available on the launching host". A hand-written
`.git/config` carrying a canonical `[remote "origin"]` / `url =` pair matches
what that parser accepts, and one has been placed at
`/home/forge/src/tillandsias/.git/config` on this host.

**NOT VERIFIED BY EXECUTION — this is a reading of the parser, not a
measurement of it.** An earlier draft of this section said "parsed correctly,
verified here", which was an overclaim: the file was written and its shape
compared against `parse_gitdir_origin_url`'s source, but the resolver was never
RUN against it. The only two callers are the 759-vceg probe inside
`run_provider_login` and `write_forge_repo_gitdir`, so exercising it needs
either a real login or a forge launch — neither available without the
operator's token.

Both controls are therefore outstanding, and the negative is the one that
matters: removing the `.git/config` and confirming the resolver then fails the
way the refusal claims is what would prove the parse was doing the work rather
than something else supplying the answer. Raised by yoga-silverblue.


**Where this claim travelled before it was retracted, since a retraction that
does not name its blast radius is half a retraction.** yoga-silverblue sourced
1212-kqcg's durable/perishable split from the "verified here" wording and
LANDED it. That row tells an implementer the perishable half (this image lacks
`git`) needs re-measuring and the durable half (the resolver survives) does not.
With the resolver-survives half unexecuted, **both halves are outstanding and
the caveat sits on the wrong one.** yoga-silverblue appended a correction event
to 1212-kqcg; the row stays `completed` because the
implementation it describes is unaffected, but the context it hands an
implementer changes materially.

That correction has LANDED: progress event
`plan/index.d/20260915t220253z-0beb4090-linux.yaml`, in commit 3a32abf85 on
`linux-next` (which also closed 1213-ysme, implementation caa724f70). The event
records that the caveat sat on the wrong half, that resolver-survives is a
reading rather than an execution, that both controls are unrun and why, and that
the negative is the one that matters.

Nobody had acted on the implementer note when this was caught. That is the only
reason it is a correction rather than a defect.
What DOES hold without execution: the fallback exists, is documented for exactly
this case, and does not depend on which image is installed.

This is the sharpest statement of the design gap — stated precisely, because the
overbroad version is tempting and wrong. The remedy is **not impossible** in the
tray lane: a checkout CAN exist there, and the resolver has a documented reader
for a hand-written `.git/config` (unexecuted — see above). What the lane lacks
is a TOOL to produce one — nothing in the guest can clone a repository.
A missing tool, not an impossibility, which is both true
and more actionable: it names something that could be added.

(Correction: an earlier draft of this section said the remedy was "impossible"
in this lane. yoga-silverblue caught it while about to write the same overbroad
claim into 1211-34v6's replacement text — a third overbroad statement inside a
conversation about overbroad statements. Kept visible rather than edited out.)


## 4c. RESOLVED: the resolver was executed, and it parsed the hand-written config

§4b above records a retraction — the claim that a hand-written `.git/config`
"is parsed correctly, verified here" was a reading of the parser, not an
execution of it, and both controls were outstanding.

**Both controls have now been run** (see §11). The operator's CLI login started
in `/home/forge/src/tillandsias`, whose only git artifact is the hand-written
`.git/config`, and it got past the push-authorization probe and wrote the token
to Vault. No `git` binary exists in that guest, so the only path that could have
resolved the origin is `parse_gitdir_origin_url` reading that file.

- **positive control:** config present -> probe resolves `8007342/tillandsias`,
  login completes, `secret/github/token` created.
- **negative control:** three tray runs from `/root`, no config on that path ->
  the `None` arm, refusal, nothing written.

So the durable half stands, now by execution rather than by reading, and the
caveat in 1212-kqcg's correction event
(`plan/index.d/20260915t220253z-0beb4090-linux.yaml`) can be closed on this
point. The retraction in §4b is left in place deliberately: it was correct when
written, and a row that deletes its own corrections teaches the next reader
nothing about how far a claim travelled.


**The two halves are NOT independent, and an implementer must know why.** The
inference above — "no `git` in the guest, therefore only `parse_gitdir_origin_url`
could have answered" — discriminates ONLY BECAUSE this image ships no `git`. On
an image that ships it, the identical successful login would prove nothing about
which resolver path answered, because the primary path would also have worked.

So §4b's perishable half is the PREMISE of §4c's durable half, not a separate
fact beside it. An implementer re-measuring the image is simultaneously
re-establishing the basis of the execution result. The correct statement is
**"the fallback resolved it ON THIS IMAGE"** — which is exactly what was needed
here, and is not a general fact about the resolver.

Raised by yoga-silverblue, whose own durable/perishable framing in 1212-kqcg
presented the two as separable; that framing is corrected on their row rather
than silently here. Resolving event:
`plan/index.d/20260915t223600z-1e47f297-linux.yaml` (commit 6f4d30a94),
following the correction it resolves
(`plan/index.d/20260915t220253z-0beb4090-linux.yaml`, commit 3a32abf85).

**Still perishable, unchanged:** the `rpm -q` measurement of this image build,
and the fact that nothing provisions that `.git/config` (§12).

## 5. The podman timeline confirms the Vault write never ran

```
13:55:18.9  container start   tillandsias-github-login-3521
13:55:19.3  exec  #1          login script
13:55:32.7  exec_died         13.4s — operator paste; gh auth login SUCCEEDED
13:55:34.4  exec  #2          gh auth status (the identity check above the probe)
13:55:35.0  exec_died         0.6s
13:55:35.4  container died, removed
```

`run_provider_login` defines four execs (login, push probe, Vault write, Vault
verify / `gh api user`). **Only two ran**, then immediate teardown — the
signature of the `None` arm returning before any probe or write.

## 6. Ruled out by measurement, not by reading

- **Vault write path is functional.** Minted a real `github-login` SecretID,
  logged in (95-char client token), wrote `secret/github/token` with that
  scoped token — `rc=0`, `version 1` — read back the exact value, then deleted
  it. Post-cleanup `kv list secret/` is identical to pre-probe
  (`mirror-identity/` only). Policy `github-login-policy` grants
  create+update+read; AppRole `github-login` exists and is bound to it.
- **Not `~/src` breaking enumeration.** yoga-silverblue read the code
  (enumeration runs `gh api user/repos` in a container and never reads a local
  checkout; `~/src` appears only in the CLONE path, which calls
  `create_dir_all(parent)` first) and measured it: `--list-cloud-projects` on a
  trunk build returned "fetched 25 remote project(s)" on a host with **no**
  `~/src` before or after.
- **Not version skew, a missing git image, or proxy/vault health.** This host is
  uniformly v56.9.12.2 across tray, guest binary and every image; the git image
  is present; vault and proxy are Up and healthy.

## 7. Latent fleet-wide, not Windows-specific

Any host that has **not re-authenticated since the `~/src` removal** is running
on a credential seeded while a checkout still existed. Those hosts work and will
keep working until they need to log in again, at which point they hit this. That
makes the defect look host-specific when it is actually latent across the fleet
and surfaces only on re-auth.

## 8. The operator's hypothesis was right about the cause, wrong about the mechanism

The operator said project listing still resolved through a checkout that no
longer exists. Two hosts read the enumeration code and correctly withdrew that —
enumeration genuinely never touches a checkout. **The checkout dependency is
real but sits upstream of enumeration entirely**, in the login's authorization
probe, two steps earlier. A hypothesis can be wrong about the mechanism and
right about the cause; checking only the named mechanism drops it.

## 9. The refusal's second remedy was inert — fixed in 1211-34v6, landed e15c81e6d

The same refusal offered two remedies and one did nothing:
`TILLANDSIAS_PROJECT_REMOTE_URL` is never consulted by this path.
`read_host_project_origin_url` falls through to `parse_gitdir_origin_url`, and
there is no `env::var` anywhere in that chain.

**That defect is yoga-silverblue's 1211-34v6, not this one.** Found by them,
verified independently here and again by macuahuitl-fedora before the ruling.
Landed `e15c81e6dae2d391a40cab23f29949c7f0834567` on `linux-next`
(`ok:land:e15c81e6d:attempt-1`), with
`tests::github_login_refusal_names_a_remedy_that_works` pinning it.

Ruled separate because the two have different costs to fix: this row is a design
decision — where should a login resolve its repository when the lane it runs in
has no checkout by construction? — and 1211-34v6 was a one-line text fix.
Folding them would have made the cheap fix wait behind the expensive decision
while a stuck operator kept reading advice that does nothing.

**What the landed text does and does not cover**, so this citation is not read
as more than it is. It names the CLI-from-a-checkout remedy; states that the
repository is resolved from the process CWD via `git config --get
remote.origin.url` with a `.git`-pointer fallback; says the tray's login cannot
satisfy that because the guest's CWD is `/root` and holds no checkout; and marks
`TILLANDSIAS_PROJECT_REMOTE_URL` inert with the reason.

It does **not** carry §4b — the finding that this guest build ships no `git` and
no `gh`, so the lane lacks the tool to produce a checkout. The landed text
accounts for the guest having no CHECKOUT, not for it having no TOOL. yoga has
filed that sharpening as **1212-kqcg** (committed 966e5f2f8), citing §4b's
measurement with its provenance and perishable flag, and instructing an
implementer to re-measure because a later image shipping `git` makes the
sharpened sentence wrong.
1212-kqcg also carries the `tray.log` pointer residue as one line, and is
pinnable by extending `tests::github_login_refusal_names_a_remedy_that_works`
rather than minting a fixture.

The fix deliberately keeps the variable NAMED and marked inert rather than
deleting it: silence would leave the next reader to rediscover why it fails and
read the absence as an oversight rather than a decided non-remedy.

A wrong remedy inside a trustworthy message is worse than no remedy: this
refusal is otherwise an unusually good error — cause, consequence, two remedies
— and that is exactly what made the inert one costly. It spends the reader's
confidence sending them somewhere that cannot work.

## 10. So the CLI lane works and the TRAY lane cannot

The distinction matters, and it is not "login is broken":

```
from a host-side checkout:
    git config --get remote.origin.url -> https://github.com/8007342/tillandsias.git
from a directory with no checkout (the guest's cwd=/root shape):
    resolves nothing
```

A CLI login run from inside a checkout resolves owner/repo and reaches the
probe. **The tray's login cannot, because it always runs in the guest**, whose
cwd is `/root` and which contains no checkout at all. This is the reason
1211-34v6's replacement text can name the CLI lane as the remedy that works
while stating outright that the tray lane cannot satisfy it.

## 11. ESTABLISHED — a controlled experiment, one variable

The diagnosis is no longer inferred. The operator ran both arms on 2026-09-15,
same host, same binary, same token, same containers, same Vault. **The only
difference between them is the process's working directory.**

```
TRAY LANE (3 runs)    cwd=/root                          -> refused, identically each time
                                                            "no GitHub upstream is configured
                                                             for this checkout ... Nothing was
                                                             written to Vault."

CLI LANE (1 run)      cwd=/home/forge/src/tillandsias    -> "[tillandsias] GitHub authentication
                                                             complete for 8007342"
```

Confirmed downstream, having been absent all evening:

```
vault kv list secret/   ->  github/          (created 2026-09-15T22:31:09Z)
                            mirror-identity/

tillandsias-headless --list-cloud-projects
                        ->  the operator's full repository list
```

**This is the negative control as well as the positive one.** The three tray
runs are the control arm: they hold everything constant and vary only the
directory, and they fail. The CLI run varies only the directory, and it
succeeds. §3's mechanism — `read_host_project_origin_url(Path::new("."))`
resolving from CWD, the `None` arm returning before the Vault write — is the
only thing that distinguishes them.

The operator's three "wasted" repeat attempts turned out to be the control arm.
They were not wasted.

## 12. What this does and does not fix

**Fixed for this host, right now:** the token is in Vault at
`secret/github/token`, which is what every consumer reads. Remote project
enumeration works. The git-mirror relay credential exists.


**End-to-end confirmed by a real push.** Shortly after the login, the operator
ran an agent session (opencode) which **pushed a commit to a remote on another
repository** from this host. That exercises the whole chain the login exists to
seed: the Vault-stored credential, the git-mirror relay reading it, and an
actual authenticated write to GitHub.

This matters more than the enumeration check, because it closes the loop on the
GUARD'S OWN PURPOSE. Order 759-vceg exists to prevent exactly one outcome — a
token that authenticates, is seeded on that basis alone, and then fails at the
first push (the 803-49re incident, where a release looked healthy and broke the
operator forty minutes later). Here the probe verified push permission BEFORE
seeding, and a subsequent real push succeeded. The verification the guard
performs was meaningful rather than ceremonial, on this run.

So the guard is vindicated twice over in this row: it correctly refused three
times when it could not verify, and the one time it did verify, the credential
it approved genuinely worked for the thing it was verified for.
**Not fixed:** the tray lane. Nothing about the product changed — the tray still
launches the login in the guest at cwd `/root`, so the next operator to use the
menu item hits the identical refusal. This row's defect is untouched; only its
symptom on one host is relieved.

**A dependency the fix does not have:** the working login depended on a
hand-written `/home/forge/src/tillandsias/.git/config` placed there by an agent,
because the guest ships no `git` to create one (§4b). That directory is not
provisioned by anything. If the guest is reprovisioned — which the tray does on
its own when a control-wire handshake fails — it goes with it, and the host
returns to the refusal with no record of why it worked before.

## 13. Remaining risk on the 1025-a896 axis

The credential now seeded is whatever the operator pasted. If it is an OAuth
`gho_` token from a device flow, it remains subject to the ten-token pool and
can still be evicted by another host's login. If it is a fine-grained PAT —
1025-a896's Option A — this host is immune going forward. Not determined here;
the login flow does not print the token type and nothing should read it back to
find out.


related: [interactive login refusal only renders in an unlogged terminal](interactive-login-refusal-only-renders-in-an-unlogged-terminal-2026-09-15-yolanda-windows.md) — WITHDRAWN
related: [the fault's output is well-formed, so only the reader it blocks can find it](the-faults-output-is-well-formed-so-only-the-reader-it-blocks-finds-it-2026-09-15-yolanda-windows.md)
related: 1211-34v6 — the inert `TILLANDSIAS_PROJECT_REMOTE_URL` remedy in this same refusal (yoga-silverblue); landed e15c81e6d
related: 1212-kqcg (yoga-silverblue) — the missing-tool sharpening of §4b, plus the tray.log pointer residue; corrected by 3a32abf85
related: [yolanda's working login rests on a file nothing provisions](yolanda-github-login-works-on-unprovisioned-state-that-will-vanish-2026-09-15-yolanda-windows.md) — the §12 fragility, filed separately because it has a clock
related: 1025-a896 — the OAuth ten-token cap; `--with-token` is outside its mechanism

---

**Tracking row: 1215-xazj** — filed by macuahuitl 2026-09-16 so this finding is selectable by `plan_next`. It had no ledger row when it landed, which meant nothing would ever route it. The diagnosis above is the evidence; the row carries only the exit criteria.
