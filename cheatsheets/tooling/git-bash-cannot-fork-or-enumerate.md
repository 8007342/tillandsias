---
tags: [msys, git-bash, wsl2, fork, credentials, enumeration, windows, false-negative, agent-safety]
languages: [bash]
since: 2026-09-20
last_verified: 2026-09-20
sources:
  - https://www.cygwin.com/faq.html#faq.using.fixing-fork-failures
  - https://learn.microsoft.com/en-us/windows/wsl/filesystems
  - https://git-scm.com/docs/gitcredentials
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---
# Git Bash cannot fork deep, and cannot reach into WSL

@trace spec:cheatsheet-tooling

**Version baseline**: Git Bash (`MINGW64_NT-10.0-26200`) on esmeraldinha,
Windows 11, driving a `tillandsias-build` WSL2 distro over `wsl.exe`.
**Use when**: you are running a project script from Git Bash and it fails in a
way that blames something else — an authentication error, or a count of files
in a directory you never actually looked at.

## Two traps, one cause

MSYS emulates POSIX on Windows, and it does so **imperfectly at two seams**:
spawning processes at depth, and passing arguments across `wsl.exe`. Both fail
**silently, with a plausible wrong answer**, and both blame an innocent
subsystem.

---

## Trap 1 — `fork` fails at depth, and git pushes anonymously

### Minimal reproduction

Run any project script that pushes, from Git Bash:

```bash
bash scripts/push-plan-fragments-to-trunk.sh
```

Observed on esmeraldinha 2026-09-20 — note the two unrelated-looking lines:

```
0 [main] sh 1983 C:\Program Files\Git\usr\bin\sh.exe: *** fatal error -
  error while loading shared libraries: C: cannot open shared object file
remote: No anonymous write access.
fatal: Authentication failed for 'https://github.com/<org>/<repo>.git/'
```

### What is actually happening

`git` runs a `!`-prefixed credential helper **through a shell**. At this process
depth — harness bash → script bash → `git` → `sh` — MSYS cannot fork `sh.exe`.
The helper never runs, git obtains no credential, and pushes **anonymously**.
The server then says `No anonymous write access`, which reads like a token
problem and is not one. The pre-push hook, also a shell script, fails to spawn
in the same breath.

**`No anonymous write access` means git sent NO credential.** It is a distinct
state from `401` (bad credential; git's store is erased) and `403` (good
credential, insufficient rights; store intact). Do not debug the token here.

### Why it resists diagnosis

Every direct test passes, because a direct test is one level shallower:

```bash
git push --dry-run --no-verify origin HEAD:refs/heads/<branch>   # works
```

A probe that does not reproduce the caller's **process depth** is not testing
the caller's channel. On the day this was found, four independent checks
(`gh auth status`, `gh api ... .permissions`, `git ls-remote`, and invoking the
helper by hand) were all green while every scripted push failed.

### The fix

**Run the script inside the distro**, where the helper chain reduces to git's
built-in `store` helper — a binary that needs no shell — and MSYS is not in the
path at all:

```bash
MSYS_NO_PATHCONV=1 wsl.exe -d <distro> -- bash -lc \
  'cd /mnt/c/<checkout> && bash scripts/push-plan-fragments-to-trunk.sh'
```

Secondary points, both measured: `gh auth setup-git` installs `!`-shell helpers,
so it does **not** fix this; and a repo-local empty `credential.helper` reset in
`.git/config` is read *after* global config and wipes whatever global helpers
were configured. Each failed attempt also leaves `git-remote-https.exe`
processes alive, and enough of them make the fork failures **more** likely — so
a retry loop degrades its own chances. `taskkill //F //IM git-remote-https.exe`
between attempts.

---

## Trap 2 — an inline `wsl.exe` string enumerates the wrong directory

### Minimal reproduction

```bash
wsl.exe -d <distro> -- bash -lc '
  D=/usr/lib/wsl/drivers
  find "$D" -maxdepth 1 -mindepth 1 | wc -l
'
```

Measured on esmeraldinha 2026-09-20: this reported **59**. The true count is
**795**. No error, no empty output, exit 0.

### What is actually happening

MSYS mangles the argument on its way to `wsl.exe`. The shell variable never
expands, so `find "$D"` becomes `find` **with no path**, which defaults to `.` —
the current directory, i.e. the repo root. It is a real enumeration of the
**wrong tree**, which is why the number looks plausible. Related symptoms from
the same seam: a `/mnt/c/...` script path rewritten to
`C:/Program Files/Git/mnt/c/...`, and `cd` appearing to fail (`rc=0`, `$PWD`
unchanged) while having actually worked.

### The fix

1. **Stage the script as a FILE**; never pass multi-line logic as an inline
   string.
2. **`MSYS_NO_PATHCONV=1`** on the `wsl.exe` invocation.
3. **Absolute paths only** inside the script. Never rely on `cd`, and never
   trust `$PWD` as the witness that it worked.
4. **Make the parts sum to the total** and print the check.

```bash
MSYS_NO_PATHCONV=1 wsl.exe -d <distro> -- bash /mnt/c/<path>/audit.sh
```

```bash
# inside audit.sh — the assertion that catches it
T=$(find "$D" -maxdepth 1 -mindepth 1 | wc -l)
DIRS=$(find "$D" -maxdepth 1 -mindepth 1 -type d | wc -l)
FILES=$(find "$D" -maxdepth 1 -mindepth 1 -type f | wc -l)
LINKS=$(find "$D" -maxdepth 1 -mindepth 1 -type l | wc -l)
echo "total=$T sum=$((DIRS+FILES+LINKS))"   # they must match
```

The sum check is what caught this. Nothing else did — not the exit status, not
stderr, not the shape of the output.

---

## The rule

**On a Windows host, a failure reported by a POSIX tool may be MSYS failing
underneath it rather than the tool telling you something true.** Before
believing a Git Bash result that blames credentials, a filesystem, or an empty
directory:

- **Re-run the same work inside the WSL distro.** If the answers differ, MSYS is
  the variable, and the distro's answer is the one to trust.
- **Reproduce the caller's process depth**, or your probe is testing a different
  thing than the failure.
- **Never truncate the output.** Both findings here were prolonged by a
  `tail -25` that hid the line naming the real cause.

## Sibling traps

[msys-grep-cannot-count-carriage-returns.md](msys-grep-cannot-count-carriage-returns.md)
— on the same hosts, `grep` cannot match a CR and `awk` cannot see one.
[awk-word-boundary.md](awk-word-boundary.md) and
[recursive-grep-symlinks.md](recursive-grep-symlinks.md) — the same family on
other platforms: **a tool that reports success while seeing the wrong thing, on
the platform running it.**

## Provenance

Both traps measured on esmeraldinha 2026-09-20 during a single session, from the
transcripts on orders 759-ffh7 (the fork/credential chain, filed as a
three-fault story), 1267-fj2z (the enumeration, where the 59-versus-795 error
was caught by the parts-must-sum check mid-audit) and 1294-7zsd (`plan(unknown)`,
the cosmetic cost of the WSL-side push route this sheet recommends). The
fork-depth trap cost roughly an hour and was misdiagnosed as a credential
problem three times before the depth was identified. Written at the
coordinator's request.
