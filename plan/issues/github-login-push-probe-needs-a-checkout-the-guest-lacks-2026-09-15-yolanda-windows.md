# `--github-login` cannot succeed on a host whose guest has no checkout

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

## 3. Where it actually fails — `main.rs:10135-10201`

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

## 9. The error message's second remedy is INERT

The refusal offers two remedies. Only the first works.

`read_host_project_origin_url` (`main.rs:3702-3722`) consults exactly two
sources — `git -C <path> config --get remote.origin.url`, then
`parse_gitdir_origin_url` reading `.git` / gitdir pointer files — and neither it
nor `sanitize_forge_origin_url` contains a single `env::var` reference.

**`TILLANDSIAS_PROJECT_REMOTE_URL` is never consulted by this path.** The
variable is real — set by the cloud-project resolver (`main.rs:6090`) and read
by the cloud lanes (`12523`, `13703`) — but the login probe's resolver does not
look at it. An operator who follows the message's own second remedy gets the
identical refusal and learns nothing.

Found by yoga-silverblue, verified independently here by reading the resolver.
Whether this is its own row or belongs in this one is macuahuitl's scope call,
pending.

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
cwd is `/root` and which contains no checkout at all.

## 11. Not yet established

Neither lane has been confirmed end to end. Proving the CLI-from-a-checkout lane
actually completes a login requires a real token paste — the operator's hands
and their token — and order 1025-a896 records that `gh auth login` evicts every
other host's credential, so it must not be run casually (doubly so while
lenovinha is wedged). The resolver step is proven; the full lane is not. That
test is the difference between this diagnosis and a fix.

related: [interactive login refusal only renders in an unlogged terminal](interactive-login-refusal-only-renders-in-an-unlogged-terminal-2026-09-15-yolanda-windows.md)
