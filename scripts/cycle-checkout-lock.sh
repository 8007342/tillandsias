#!/usr/bin/env bash
# @trace order:873-zcim
# cycle-checkout-lock.sh — the CHECKOUT lock, acquirable from EVERY lane.
#
# ORDER 873-zcim. The no-stacking lock existed and was held — by the driver
# lane only. scripts/tillandsias-cycle-driver.sh takes a non-blocking flock on
# <git-dir>/tillandsias-cycle.lock around its whole cycle, so the DRIVER never
# stacks on itself. But a cycle started any other way — an operator prompt, a
# Claude Code /loop cron, a cloud schedule, a human typing the sentence —
# acquired NOTHING. On 2026-08-24 a 4-hourly /loop fired on yoga 21 minutes
# into a running driver cycle in the same worktree; the newcomer could see the
# driver's lock but had no way to take one of its own, and the driver cannot
# refuse a stacker it cannot see. Four hours earlier on the same host, one
# process's disposal of a worktree destroyed another's uncommitted work
# (872-c9nd). The lock guarded the driver lane; the thing two agents actually
# contend for is the CHECKOUT.
#
# WHY THE PROMPT LANES CANNOT USE THE FLOCK ARM. flock guards an open file
# descriptor and releases when the holding process exits. The driver IS one
# process wrapping its whole cycle, so that works. A skill-driven cycle is a
# CHAIN of short-lived shells — no single process spans it, so there is no fd
# to hold. These lanes use the mkdir arm (atomic, survives process exit) with
# the AGENT HARNESS pid as the liveness anchor: the parent of the tool shells
# (e.g. the `claude` process) lives for the whole session and `pid_is_live` on it
# answers "is that cycle still possibly running".
#
# CROSS-ARM VISIBILITY, both directions, or the gap just moves:
#   - acquire here takes the mkdir dir FIRST (the atomic claim among prompt
#     lanes), then PROBES the driver's flock; if the driver holds it, we
#     release our dir and skip.
#   - the driver, after winning its flock, now ALSO checks this dir
#     (liveness-aware) and skips if a prompt-lane cycle holds it.
#   A simultaneous grab can make BOTH back off for one tick; both fire again
#   on their own clocks, and a skipped tick is the designed outcome (the
#   driver's own words). Livelock resolves at the next uncontended fire.
#
# EXIT CRITERION 3: a cycle refused for overlap must be distinguishable from a
# cycle that ran and found nothing. The refusing cycle must NOT write into the
# contended checkout — that is the hazard being refused — so the durable
# record goes OUTSIDE it: one JSONL line per refusal in
# ${TILLANDSIAS_CYCLE_STATE_DIR:-~/.cache/tillandsias}/overlap-refusals.jsonl,
# carrying who was refused and who held. The coordinator can sweep that file.
#
# EXIT CRITERION 4, DECIDED: a second agent NEVER works in a locked checkout.
# The sanctioned path for concurrent work on one host is a separate worktree
# or a clean temp clone (the technique yoga used for both its wedge record and
# the 873-zcim filing itself). This script therefore has no "join" mode on
# purpose; asking for one is asking to be the 872-c9nd incident.
#
# Grammar (last line on stdout):
#   ok:checkout-lock:acquired:<lane>:<pid>
#   ok:checkout-lock:released
#   ok:checkout-lock:free            (status mode)
#   skip:overlap-lock-held:<holder-description>
#   fail:checkout-lock:<reason>
#
# Usage:
#   scripts/cycle-checkout-lock.sh acquire [--lane <name>] [--source <text>]
#   scripts/cycle-checkout-lock.sh release
#   scripts/cycle-checkout-lock.sh status
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "fail:checkout-lock:not-a-repo"; exit 2; }
GIT_DIR="$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null)" || { echo "fail:checkout-lock:no-git-dir"; exit 2; }
LOCK="$GIT_DIR/tillandsias-cycle.lock"
LOCKD="$LOCK.d"
STATE_DIR="${TILLANDSIAS_CYCLE_STATE_DIR:-$HOME/.cache/tillandsias}"
# The liveness anchor: the agent-harness process that spans the whole cycle.
#
# CALLERS MUST PASS TILLANDSIAS_CYCLE_HOLDER_PID=$PPID FROM THEIR OWN SHELL.
# The default below — this script's $PPID — is one level too deep for an
# agent-tool invocation: it resolves to the tool-call wrapper shell, which
# dies the moment the call returns, so the lock's holder is dead within
# seconds and the next acquire stale-reclaims it. Measured live during
# 873-zcim's own bring-up: the first acquire recorded pid 1695105 (the
# wrapper), dead one tool-call later. Evaluated in the CALLER's shell, $PPID
# is the harness process (e.g. `claude`, alive for the whole session), which
# is the identity that actually spans the cycle.
# ORDER 1091-zh6d. THE DEFAULT IS REACHABLE BY TYPING THE OBVIOUS COMMAND, and
# it is silently wrong. `scripts/cycle-checkout-lock.sh acquire` with no
# variable evaluates $PPID INSIDE this script, where it is the tool shell that
# invoked us — dead the moment that tool call returns. The lock stale-reaps at
# once, every later lane reads `ok:checkout-lock:free`, and the verdict the
# caller saw said `acquired`. Measured on yoga 2026-09-06, direct and via
# `bash -c`: both anchor on the dying shell, never the harness.
#
# CLAUDE_PID is preferred over $PPID because it makes the BARE path correct
# rather than merely diagnosable — the harness exports it, so no ancestry walk,
# no hop counting, and nothing that differs between linux, darwin and msys.
# Two Linux hosts measured the harness exactly one ppid hop up, which is the
# kind of agreeing evidence that would justify $PPID and then break on the
# first nested shell.
#
# The chain is NAMED in the verdict (see `anchor_source`) because a silent
# fallback to the invoking shell is precisely today's defect wearing a new
# code path. Other backends (codex, opencode, gemini) have no CLAUDE_PID and
# must supply TILLANDSIAS_CYCLE_HOLDER_PID themselves.
if [ -n "${TILLANDSIAS_CYCLE_HOLDER_PID:-}" ]; then
    HOLDER_PID="$TILLANDSIAS_CYCLE_HOLDER_PID"
    anchor_source="explicit"
elif [ -n "${CLAUDE_PID:-}" ]; then
    HOLDER_PID="$CLAUDE_PID"
    anchor_source="harness-env"
else
    HOLDER_PID="$PPID"
    anchor_source="invoking-shell-UNVERIFIED"
fi

# Is pid $1 running? THE ONE LIVENESS PRIMITIVE — every lock decision that asks
# "is the recorded holder still there" goes through here, so a host where the
# answer is wrong is wrong in ONE place rather than four.
#
# `kill -0` alone is NOT that primitive on Windows, and the gap is silent.
# Under MSYS/Cygwin bash, `kill` speaks MSYS pids, while the anchor a claude
# harness exports (CLAUDE_PID) — and anything `ps -W` reports as WINPID — is a NATIVE
# Windows pid from a different numbering space. MEASURED on yolanda
# 2026-09-12: CLAUDE_PID=12388, `tasklist /FI "PID eq 12388"` listing a running
# claude.exe, and `kill -0 12388` answering "No such process".
#
# The consequence was not a warning, it was the ABSENCE OF THE LOCK. Every
# Windows anchor was stamped `-DEAD`, every recorded holder read stale, and a
# second lane calling `status` one command after a successful acquire got
# `ok:checkout-lock:free`. Both Windows hosts ran with no mutual exclusion at
# all — the 873-zcim guard present, green, and inert — and the warn verdict's
# FIX line sent the operator to put the variable on the command line, which it
# already was. The fixture could not see any of it because every arm anchors on
# `$$`, an MSYS pid, which is the one kind `kill -0` resolves correctly here;
# arm 8 closes that.
#
# THE FALLBACK IS `ps -W`, NOT `tasklist`, and the choice is load-bearing twice
# over. esme validated this predicate independently on esmeraldinha and made the
# case for it (plan/issues/checkout-lock-inert-on-windows-hosts-2026-09-12.md):
# `ps -W` exposes WINPID as its own column, so nothing is parsed out of
# human-facing text that varies by locale. And it keeps `tasklist` UNUSED here,
# which is what lets the fixture attest liveness through a mechanism this
# function does not share — a probe confirmed only by itself is not confirmed.
#
# The locale point is not theoretical. The obvious `tasklist /NH /FI "PID eq $p"`
# form was written first and rejected on measurement: its output is
# space-padded columns (image, pid, session name, SESSION NUMBER, memory), so a
# whitespace-delimited match for the pid also matches the session-number column
# — `pid 1` reads live on any host with a session 1, which is every one. `PPID=1`
# is exactly the value Git Bash reports to a tool shell (esme, same writeup), so
# the one pid most likely to be probed here is the one that form gets wrong.
#
# ORDERING: `kill -0` stays first and answers alone on linux and darwin, so
# this is a no-op off Windows by construction rather than by test — which is
# also why it cannot disturb the green arms of
# scripts/test-cycle-lock-attested-release.sh.
pid_is_live() {
    local p="${1:-}"
    [ -n "$p" ] || return 1
    case "$p" in *[!0-9]*) return 1 ;; esac
    kill -0 "$p" 2>/dev/null && return 0
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*)
            ps -W 2>/dev/null | awk -v p="$p" '$4 == p { found=1 } END { exit !found }'                 && return 0
            ;;
    esac
    return 1
}

# VALIDATE THE VALUE RATHER THAN TRUSTING IT. An env var inherited into an
# unrelated context would anchor the lock to a live process with nothing to do
# with this cycle — presence used as proof, which is the arm-1 defect of
# check-credential-channel.sh one layer over. A dead anchor is worse still: the
# lock would be born stale.
if ! pid_is_live "$HOLDER_PID"; then
    anchor_source="${anchor_source}-DEAD"
fi
# Staleness bound: same 10800s (2x the 90m cycle cap) the driver uses.
STALE_S=10800

lane="prompt"
source_desc="unspecified"
probe_pid=""

now() { date +%s; }

dir_holder_desc() {
    printf 'lane=%s pid=%s since=%s source=%s' \
        "$(cat "$LOCKD/lane" 2>/dev/null || echo '?')" \
        "$(cat "$LOCKD/pid" 2>/dev/null || echo '?')" \
        "$(cat "$LOCKD/epoch" 2>/dev/null || echo '?')" \
        "$(cat "$LOCKD/source" 2>/dev/null || echo '?')"
}

# Parent pid of $1, or empty if this host offers no way to ask.
#
# THREE LANES, TWO MECHANISMS, AND THE ONE THAT LOOKS PORTABLE IS NOT.
# Measured 2026-08-26, the day the first version of this shipped red:
#   linux   /proc present;  `ps -o ppid=` works
#   msys    /proc present;  `ps` REFUSES -o entirely ("unknown option -- o")
#   darwin  /proc ABSENT;   `ps -o ppid=` works
# So `/proc` first and `ps -o` second covers all three, and neither alone does.
#
# DO NOT "simplify" this to `ps -p <pid> | awk 'NR==2{print $2}'`. Column 2 is
# PPID on MSYS but TTY on Linux (measured: prints `?`), so that form returns a
# confident wrong answer on the lane where the current code happens to work —
# the exact trade this function was already caught making once.
_ppid_of() {
    local p="$1" v=""
    if [ -r "/proc/$p/stat" ]; then
        # `comm` (field 2) may contain spaces and parens, so split after the
        # LAST ')' rather than tokenising the whole line: state, then ppid.
        v="$(sed -e 's/^.*) //' "/proc/$p/stat" 2>/dev/null | awk '{print $2}')"
    fi
    if [ -z "$v" ]; then
        v="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d '[:space:]')"
    fi
    case "$v" in *[!0-9]*|"") v="" ;; esac
    printf '%s' "$v"
}

# Is $1 this process, or any ancestor of it? Used by `mark-attested`, which is
# invoked BY the holding cycle and therefore runs strictly below the harness pid
# the lock records. Bounded depth so a malformed /proc or a pid-namespace
# surprise cannot spin.
#
# Exit 0 = yes. Exit 1 = no. Exit 2 = COULD NOT DETERMINE — distinct on purpose.
# The first version returned plain "no" when the probe failed, which on MSYS
# meant every ownership test answered `held-by-other` about the caller's own
# lock, with nothing in the output saying the walk had failed. A probe that
# cannot answer must say so rather than pick the answer that looks like data.
pid_is_self_or_ancestor() {
    local target="$1" p=$$ depth=0 next
    [ -n "$target" ] || return 1
    while [ "$depth" -lt 40 ] && [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ]; do
        [ "$p" = "$target" ] && return 0
        next="$(_ppid_of "$p")"
        # Depth 0 failing means the host has no working mechanism at all; deeper
        # failures are a normal walk terminus (reaped parent, namespace edge).
        if [ -z "$next" ]; then
            [ "$depth" -eq 0 ] && return 2
            return 1
        fi
        p="$next"
        depth=$(( depth + 1 ))
    done
    return 1
}

dir_lock_live() {
    [ -d "$LOCKD" ] || return 1
    # A holder that has ALREADY ATTESTED is finished, whatever its pid is still
    # doing (order 899-q9di). Finalization step 9 states four times that the
    # MO-FULL marker is the cycle's FINAL OUTPUT LINE; step 9b then asks for a
    # release AFTER it. An agent that obeys the more emphatic rule ends at the
    # marker and never releases, so the lock outlives the cycle.
    #
    # On a host whose harness process spans many cycles — an agent session
    # rather than a cron that exits — the "dead holder" escape never fires, so
    # the stale bound is the FULL 3h. MEASURED on macuahuitl 2026-08-26T03:38Z:
    # the hourly fire was refused `skip:overlap-lock-held` by pid 2393229, which
    # was its own $PPID, a live `claude` 07:56:39 old that had emitted a valid
    # MO-FULL an hour earlier after promoting v0.4.260826.1 to stable.
    #
    # `record` writes this marker and runs exactly ONCE per cycle, which is why
    # it is the hook rather than `self` (callable any number of times mid-cycle,
    # so releasing on it would free the checkout while work continues).
    [ -f "$LOCKD/attested" ] && return 1
    local pid born age
    pid="$(cat "$LOCKD/pid" 2>/dev/null || true)"
    born="$(cat "$LOCKD/epoch" 2>/dev/null || echo 0)"
    case "$born" in *[!0-9]*|"") born=0 ;; esac
    age=$(( $(now) - born ))
    [ -n "$pid" ] && pid_is_live "$pid" && [ "$age" -le "$STALE_S" ]
}

# Is the DRIVER's flock held? Probe without keeping it: if we can take it, the
# driver is not running, and closing the fd releases our probe instantly.
driver_flock_held() {
    command -v flock >/dev/null 2>&1 || return 1
    ( exec 9>>"$LOCK"; flock -n 9 ) 2>/dev/null && return 1
    return 0
}

record_refusal() {
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    printf '{"ts":"%s","event":"overlap-refused","refused_lane":"%s","refused_source":"%s","holder":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$lane" "$source_desc" "$1" \
        >> "$STATE_DIR/overlap-refusals.jsonl" 2>/dev/null || true
}

cmd="${1:-status}"; shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --lane)   shift; lane="${1:-prompt}" ;;
        --source) shift; source_desc="${1:-unspecified}" ;;
        # ppid-probe only: ask about a pid the CALLER knows the parent of, so a
        # test can cross-check the answer instead of taking it on faith.
        --pid)    shift; probe_pid="${1:-}" ;;
        *) echo "fail:checkout-lock:unknown-arg:$1"; exit 2 ;;
    esac
    shift || true
done

case "$cmd" in
    acquire)
        # ORDER 1098-q7bk — REFUSE an UNVERIFIED anchor rather than acquire
        # over it. 1091-zh6d made this path say so (warn:, below); a warning
        # printed to a lane that then keeps working still leaves two lanes in
        # one checkout, because the lock it took is already dead. Refusing is
        # the only outcome that makes the bare path SAFE without moving the
        # anchor — and moving the anchor is out of scope for a measured reason
        # (dir_lock_live's 3h over-hold on a session harness, 2026-08-26).
        #
        # MEASURED on pirria 2026-09-12 against pristine origin/linux-next,
        # bare acquire in a subshell that then exits:
        #     warn:checkout-lock:acquired-unverified-anchor:prompt:134628
        #     recorded holder 134628 -> DEAD once the subshell returned
        #     status from a fresh subshell -> ok:checkout-lock:free
        # The lock evaporated across the boundary while the verdict said the
        # caller held it.
        #
        # KEYED ON anchor_source, NOT on TILLANDSIAS_CYCLE_HOLDER_PID being
        # empty. CLAUDE_PID is a verified anchor since 1091-zh6d, so testing
        # the variable would refuse the harness path that resolves correctly
        # and break the CLAUDE_PID-only control in
        # test-cycle-lock-attested-release.sh. Only the invoking-shell
        # fallback is refused; explicit and harness-env still acquire, and a
        # dead EXPLICIT anchor keeps its existing warn.
        case "$anchor_source" in
            invoking-shell-UNVERIFIED*)
                echo "refused:checkout-lock:no-holder-pid"
                {
                    echo "  ANCHOR: $anchor_source — this lock would be anchored to the shell"
                    echo "  that invoked the script, which dies when your tool call returns."
                    echo "  It would stale-reap immediately and the next lane would read"
                    echo "  ok:checkout-lock:free while you are still working (1098-q7bk)."
                    echo "  REFUSED rather than acquired: you do NOT hold this checkout."
                    echo "  FIX: put the variable on the command line, in YOUR shell —"
                    echo "    TILLANDSIAS_CYCLE_HOLDER_PID=\$PPID $0 acquire --lane <l> --source <s>"
                    echo "  \$PPID, NOT \$\$: inside a tool-invoked shell \$\$ is that shell, which"
                    echo "  is about to exit — it would anchor the lock to the very process"
                    echo "  whose death is this bug. \$PPID is the harness that spans the cycle."
                    echo "  A claude harness exports CLAUDE_PID and needs neither."
                    echo "  See skills/advance-work-from-plan section 1b."
                } >&2
                exit 2
                ;;
        esac
        # 1. The atomic claim among prompt lanes.
        if ! mkdir "$LOCKD" 2>/dev/null; then
            if dir_lock_live; then
                h="$(dir_holder_desc)"
                record_refusal "$h"
                echo "skip:overlap-lock-held:$h"
                exit 0
            fi
            # Stale (dead holder or beyond the bound): reclaim; the mkdir race
            # after rm elects exactly one winner, as in the driver.
            rm -rf "$LOCKD" 2>/dev/null || true
            if ! mkdir "$LOCKD" 2>/dev/null; then
                h="$(dir_holder_desc)"
                record_refusal "$h"
                echo "skip:overlap-lock-held:$h"
                exit 0
            fi
        fi
        printf '%s\n' "$HOLDER_PID" > "$LOCKD/pid"
        now > "$LOCKD/epoch"
        printf '%s\n' "$lane" > "$LOCKD/lane"
        printf '%s\n' "$source_desc" > "$LOCKD/source"
        # 2. Back off if the DRIVER holds its flock — it cannot see our dir
        #    mid-cycle (it checks only at start), so we yield to it.
        if driver_flock_held; then
            rm -rf "$LOCKD" 2>/dev/null || true
            record_refusal "driver-flock (tillandsias-cycle-driver.sh mid-cycle)"
            echo "skip:overlap-lock-held:driver-flock"
            exit 0
        fi
        # ORDER 1091-zh6d: the verdict NAMES its anchor. An `acquired` over an
        # anchor that dies with the tool call is the defect; saying which
        # anchor was used is what makes it visible at the moment it happens,
        # rather than three lanes later when the lock reads free.
        case "$anchor_source" in
            explicit|harness-env)
                echo "ok:checkout-lock:acquired:$lane:$HOLDER_PID"
                ;;
            *)
                # THE ONLY INPUTS THAT REACH HERE ARE THE `-DEAD` ONES.
                # `invoking-shell-UNVERIFIED*` is refused and exits above, so
                # the caller standing here NAMED a pid (explicitly, or via the
                # harness) and that pid did not answer the liveness probe. The
                # old text told them to put the variable on the command line —
                # advice for a case that can no longer arrive, and which on
                # Windows sent the operator chasing a shell-syntax fix for what
                # was actually a broken probe (yolanda 2026-09-12). Say what is
                # true instead: the anchor you named is not running.
                echo "warn:checkout-lock:acquired-dead-anchor:$lane:$HOLDER_PID"
                {
                    echo "  ANCHOR: $anchor_source — pid $HOLDER_PID did not answer the"
                    echo "  liveness probe, so this lock is born stale: it will be"
                    echo "  reclaimed and the next lane will read ok:checkout-lock:free"
                    echo "  while you are still working (1091-zh6d)."
                    echo "  FIX: anchor on a process that spans the whole cycle — the agent"
                    echo "  harness, not a shell that exits with your tool call. A claude"
                    echo "  harness exports CLAUDE_PID and needs nothing; other backends pass"
                    echo "    TILLANDSIAS_CYCLE_HOLDER_PID=<harness pid> $0 acquire ..."
                    echo "  If the pid IS running, the probe is wrong on this host, not your"
                    echo "  command: check it directly with \`$0 pid-probe --pid $HOLDER_PID\`"
                    echo "  and report the verdict line. See skills/advance-work-from-plan 1b."
                } >&2
                ;;
        esac
        ;;
    release)
        # Only the holder (or a cleanup after its death) should release; a
        # mismatched pid refuses rather than silently freeing someone else's
        # cycle — the failure mode this lock exists to prevent.
        if [ -d "$LOCKD" ]; then
            held_pid="$(cat "$LOCKD/pid" 2>/dev/null || true)"
            if [ -n "$held_pid" ] && [ "$held_pid" != "$HOLDER_PID" ] && pid_is_live "$held_pid"; then
                echo "fail:checkout-lock:held-by-other:$(dir_holder_desc)"
                exit 1
            fi
            rm -rf "$LOCKD" 2>/dev/null || true
        fi
        echo "ok:checkout-lock:released"
        ;;
    mark-attested)
        # Called by `mo-full-attest.sh record` once the verified marker is in
        # the ledger (order 899-q9di). Marks the cycle finished so the NEXT
        # acquire reclaims the lock instead of refusing to the holder's own
        # successor. Best-effort and never fatal: a cycle that attested but
        # could not mark simply falls back to the pre-existing stale bound.
        #
        # Refuses for a lock held by a DIFFERENT live pid, for the same reason
        # `release` does — marking someone else's in-flight cycle "done" would
        # hand their checkout away, which is precisely what 873-zcim prevents.
        if [ -d "$LOCKD" ]; then
            held_pid="$(cat "$LOCKD/pid" 2>/dev/null || true)"
            # OWNERSHIP HERE IS ANCESTRY, NOT EQUALITY, and that is the whole
            # reason this is a subcommand rather than an inline `[ = ]`.
            # `record` is invoked BY the holding cycle, so it runs one or more
            # levels BELOW the harness process the lock names — the same depth
            # problem the HOLDER_PID comment above documents for `acquire`.
            # An equality test would call the holder "someone else" and refuse
            # to mark every lock it was written to mark.
            # ANCHOR EQUALITY IS A SUFFICIENT OWNERSHIP PROOF, and it is
            # checked FIRST because the ancestry walk cannot supply it on
            # Windows. `record` runs under the same cycle that acquired, so it
            # passes the same HOLDER_PID the lock recorded; when those match we
            # are the holder and no walk is needed. The walk remains for the
            # case the ancestry comment describes — a caller some levels below
            # the harness that did not inherit the variable.
            #
            # Without this, the pid_is_live fix above would REGRESS Windows
            # rather than repair it: on MSYS the walk climbs MSYS pids from
            # `$$` and the lock records a NATIVE pid (CLAUDE_PID), so it can
            # never reach the target and answers "no". Previously `kill -0`
            # then called that native pid dead and the block fell through to
            # marking; with a liveness probe that answers correctly, the same
            # walk would instead refuse `held-by-other` about the cycle's own
            # lock — every mark-attested on both Windows hosts.
            if [ -n "$held_pid" ] && [ "$held_pid" != "$HOLDER_PID" ]; then
                pid_is_self_or_ancestor "$held_pid"; anc=$?
                if [ "$anc" -eq 2 ]; then
                    # No working ppid mechanism on this host. Say THAT, rather
                    # than reporting the lock as someone else's — which is what
                    # the first version did on MSYS, silently and every time.
                    echo "fail:checkout-lock:ancestry-unavailable:no-ppid-mechanism"
                    exit 3
                fi
                if [ "$anc" -ne 0 ] && pid_is_live "$held_pid"; then
                    echo "fail:checkout-lock:held-by-other:$(dir_holder_desc)"
                    exit 1
                fi
            fi
            now > "$LOCKD/attested" 2>/dev/null || true
            echo "ok:checkout-lock:marked-attested"
        else
            echo "ok:checkout-lock:no-lock-held"
        fi
        ;;
    ppid-probe)
        # Exposes the ancestry PRIMITIVE so every lane can test it directly,
        # instead of discovering it is broken through a guard built on top of it.
        # This subcommand exists because the first version of pid_is_self_or_ancestor
        # shipped green on linux/darwin and red on msys, and the failure surfaced
        # as a WRONG OWNERSHIP VERDICT rather than as "the probe does not work
        # here". A guard that reads host state needs its state-reading primitive
        # tested on every lane BEFORE the guard lands (yolanda, 2026-08-26).
        _pp="$(_ppid_of "${probe_pid:-$$}")"
        if [ -n "$_pp" ]; then
            echo "ok:ppid-probe:$_pp"
        else
            echo "fail:ppid-probe:no-mechanism"
            exit 1
        fi
        ;;
    pid-probe)
        # Exposes the LIVENESS primitive, for the same reason `ppid-probe`
        # exposes the ancestry one: this guard reads host state, and when the
        # state-reading primitive is wrong the symptom is a confident wrong
        # VERDICT ("free", "DEAD") rather than "the probe does not work here".
        # That is exactly how the Windows gap survived — acquire said the
        # anchor was dead, status said the checkout was free, and nothing said
        # `kill -0` could not see a native pid.
        #
        # Defaults to this shell so a bare call is always answerable; pass
        # --pid to ask about a pid the caller independently knows the state of,
        # which is the cross-check a fixture (or a sibling host) needs.
        _pp="${probe_pid:-$$}"
        if pid_is_live "$_pp"; then
            echo "ok:pid-probe:live:$_pp:$(uname -s 2>/dev/null || echo unknown)"
        else
            echo "ok:pid-probe:dead:$_pp:$(uname -s 2>/dev/null || echo unknown)"
        fi
        ;;
    status)
        if dir_lock_live; then
            echo "skip:overlap-lock-held:$(dir_holder_desc)"
        elif driver_flock_held; then
            echo "skip:overlap-lock-held:driver-flock"
        else
            echo "ok:checkout-lock:free"
        fi
        ;;
    *)
        echo "fail:checkout-lock:unknown-command:$cmd"
        exit 2
        ;;
esac
