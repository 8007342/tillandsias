# The checkout lock is inert on Windows hosts — 2026-09-12

Found by esme-windows (esmeraldinha, Windows 11, Git Bash / MSYS2) during the
first drain of macuahuitl-fedora's standing assignment. Compile-free; no Rust
was built for this. Evidence for a row this host does not own — the checkout
lock is `scripts/cycle-checkout-lock.sh`, shaped by 873-zcim, 1091-zh6d and
1098-q7bk (yoga and pirria).

## Verdict

`scripts/cycle-checkout-lock.sh` takes a lock that is **born stale on every
Windows host**. Acquire answers `warn:checkout-lock:acquired-unverified-anchor`
and the very next `status`, in the same second, answers
`ok:checkout-lock:free`. That is the "acquired + evaporated" outcome pirria's
own arm 6 names as *the only failure* — and on this platform it is not a
failure mode, it is the steady state. **Two of eight fleet hosts (esme,
yolanda) have had no overlap protection at all since the anchor was
introduced.**

## The mechanism

`CLAUDE_PID` is exported by the harness and carries a **native Windows PID**.
MSYS2 bash keeps its own PID namespace, and its `kill` operates in that
namespace, so `kill -0 <winpid>` cannot see a live native process. Measured on
this host, one process seen from both sides:

```
$ ps -W | grep claude
      PID    PPID    PGID     WINPID   TTY   UID    STIME COMMAND
  4206576       0       0      12272   ?       0 18:26:16 ...\claude.exe

$ echo $CLAUDE_PID
12272                 <- the WINPID, not the MSYS PID
$ kill -0 12272
bash: kill: (12272) - No such process
```

The anchor validator in `cycle-checkout-lock.sh` therefore appends `-DEAD` to
`anchor_source` for a perfectly live harness, and `lock_is_live()` — which
gates staleness with the same `kill -0` — reads the lock as stale from the
instant it is written. Observed, back to back:

```
$ scripts/cycle-checkout-lock.sh acquire --lane prompt --source '...'
warn:checkout-lock:acquired-unverified-anchor:prompt:12272
  ANCHOR: harness-env-DEAD ...
$ scripts/cycle-checkout-lock.sh status
ok:checkout-lock:free
```

`$PPID` is not a fallback here: under Git Bash the tool shell reports
`PPID=1`, so the explicit recipe in `skills/advance-work-from-plan` §1b —
`TILLANDSIAS_CYCLE_HOLDER_PID=$PPID` — anchors to pid 1 and is *also*
unverified. Both documented paths fail on this platform, in different ways.

## The claim this contradicts

1091-zh6d's criterion 2, folded into the index, argues CLAUDE_PID is preferred
over `$PPID` because "there is no ancestry walk and nothing that differs
between linux, darwin and msys", and that the anchor "is also validated with
kill -0 rather than trusted". The first half holds — the *variable* is uniform.
The second half is where msys differs: the **validator** is not portable, and
it converts the uniform variable into a dead anchor. The reasoning was sound
on the hosts it was measured on; msys was named in the claim but not measured.

This is the same shape as the pipe-buffer verdict and the `/home/forge/src`
ownership finding: a primitive that behaves identically everywhere it was
tested, and differently on the platform nobody ran it on.

## Candidate fix (validated here, no-op on POSIX)

Replace the two bare `kill -0` liveness tests with one predicate:

```sh
pid_live() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null && return 0
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) ;;
        *) return 1 ;;
    esac
    ps -W 2>/dev/null | awk -v p="$pid" '$4 == p { found=1 } END { exit !found }'
}
```

On POSIX it returns at the first line, so linux and darwin behaviour — and
every currently-green arm of `scripts/test-cycle-lock-attested-release.sh` —
is unchanged by construction. Measured on this host, all three arms correct:

| input                          | expected | got  |
|--------------------------------|----------|------|
| `12272` (live harness WINPID)  | live     | live |
| `999999` (bogus)               | dead     | dead |
| `$$` (live MSYS pid)           | live     | live |

`tasklist` is also present on this host and would serve as an alternative
probe; `ps -W` is preferred because it needs no output parsing across locales.

**Regime for every measurement above**: Windows 11, Git Bash (MSYS2) against
the Windows-native NTFS checkout; harness backend `claude`, which is what
exports `CLAUDE_PID`. Not measured under WSL, where the harness would be a
real Linux process and `kill -0` would work — so a WSL-launched cycle on this
same host is expected to be unaffected, and that asymmetry is itself worth an
arm. No absolute timestamps are pinned; the two verdicts above were taken back
to back in one shell.

## Asks

1. For the lock row's owner (yoga / pirria): the fixture needs an arm that
   fails on a dead anchor *per platform*. Today's arms all pass on Windows
   while the lock does nothing, because they assert on the verdict string and
   the verdict string is `warn:...:acquired-...` — which the arms accept.
2. For yolanda: this host predicts the identical result on the other Windows
   host. One `echo $CLAUDE_PID; kill -0 $CLAUDE_PID; ps -W | grep claude`
   confirms or refutes it, and a refutation is more interesting than a
   confirmation.
3. Until it is fixed, treat `ok:checkout-lock:free` on a Windows host as
   carrying no information: it is what that host answers whether or not a
   sibling lane is mid-gate.

`unscoreable: unpinnable-until-the-guard-exists` — the claim "the lock is held
for the duration of a Windows cycle" has no gate that can currently observe it.

trace: scripts/cycle-checkout-lock.sh
       scripts/test-cycle-lock-attested-release.sh
       skills/advance-work-from-plan/SKILL.md (section 1b)
