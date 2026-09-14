#!/usr/bin/env bash
# @trace order:1141-vf9w, spec:ci-release
#
# lib-dispatch-reap.sh — the ONE implementation of "carry TERMINATION across a
# dispatch boundary", the sibling of lib-env-forward.sh.
#
# PLATFORM SUPPORT, READ THIS FIRST (1141-vf9w darwin arm, 2026-09-13): this
# file works on hosts with /proc. On macOS it is UNSUPPORTED and says so —
# `unsupported:dispatch-reap:no-proc`, non-zero to the caller — rather than
# returning a quiet success having reaped nothing. See the NINTH IDIOM CLASS
# note above tillandsias_dispatch_reap_supported for why no portability
# advisory in the tree would have caught this, and the child packet of
# 1141-vf9w for the darwin design that would make it work.
#
# WHY A SHARED FILE, ON THE FIRST BOUNDARY RATHER THAN THE SECOND. 891-5shq
# exists because the toolbox boundary learned to forward the TILLANDSIAS_
# namespace and the WSL boundary then received its own separate copy of the
# same four lines; its fourth exit criterion is that a THIRD dispatch must not
# be able to diverge silently. This is the same lesson one axis over — that
# boundary did not carry FLAGS inward, this one did not carry TERMINATION
# inward — and scripts/with-wsl2-builder.sh dispatches the same way, so the
# second instance of this defect already exists in the tree. Sharing now makes
# divergence impossible instead of detectable later.
#
# THE DEFECT. `exec toolbox run ...` replaces the wrapper, and `toolbox run` is
# a thin client of `podman exec`; the container-side process is parented by
# CONMON, not by the client. So killing the host side reaps the client and
# leaves the work running in the same checkout. Measured on yoga 2026-09-13
# with a real gate mid-run: after SIGTERM reaped the host side, the
# container-side `bash ./build.sh --check` was still alive with a live child
# writing a test transcript. pirria measured one still running TWELVE MINUTES
# after its launcher was stopped, with test-archiver-ruby-could-not-run.sh as
# its live child, concurrent with a second gate.
#
# A MARKER, NEVER A COMMAND-LINE MATCH. A stray and a healthy concurrent gate
# run the SAME argv, so matching on the command line would kill the wrong one —
# and killing a legitimate gate is a worse failure than the one being fixed.
# Every process of a dispatch carries a unique token in its ENVIRONMENT
# instead, so the kill set is exactly that dispatch's tree.
#
# REQUIRES A SHARED PID NAMESPACE to see the far side. A toolbox has one
# (verified on yoga: `ps` inside reports pid 1 as the host's systemd, 436
# processes). Where that does not hold, _tb_marked_pids finds nothing and the
# reap is a NO-OP THAT SAYS SO rather than a silent success — a caller must be
# able to tell "nothing to reap" from "cannot see anything to reap".

# Mint a token for one dispatch. Exported so it crosses via the TILLANDSIAS_
# namespace that lib-env-forward.sh forwards.
tillandsias_dispatch_token() {
    printf 'tb-%s-%s-%s%s\n' "$$" "${EPOCHSECONDS:-0}" "${RANDOM}" "${RANDOM}"
}

# Pids whose environment carries $1. Never this process.
#
# BUILTINS ONLY, AND THE REASON IS THE TRAP PATH. The first version ran
# `tr | grep` per pid: 819ms per scan over 438 pids on yoga, and
# tillandsias_reap_marked polls up to 20 times, so a reap could spend ~16s
# spawning ~16000 processes WHILE THE CALLER IS TRYING TO DIE. A reaper that
# slow is a reaper that gets SIGKILLed before it finishes, which is the defect
# it exists to fix.
#
# `read -r -d ''` AND NOT `mapfile`. The obvious builtin for a NUL-separated
# file is `mapfile -d ''`, and it is bash 4.4+; macOS ships bash 3.2, so it
# would have errored on every darwin host and then reported a violation
# against a healthy tree (1055-6yp8). check-bash-dialect refused this file for
# exactly that on its first landing attempt — the guard earned its keep.
# `read -r -d ''` is bash 3.2-clean, equally free of subprocesses, and the
# loop's redirect keeps it out of a subshell so `break` still works.
#
# `[ -r ]` FIRST, because most of /proc is not ours. An unreadable environ is
# reported by the SHELL performing the redirect, not by the command being
# redirected, so a `2>/dev/null` on the inner command does NOT silence it —
# the first version printed ~300 permission errors per scan straight down the
# caller's stderr, in a handler that runs while a gate is being cancelled.
# The GROUP is redirected here for the residue that passes access(2) and still
# denies the read. An unreadable pid is never ours, so skipping it loses
# nothing.
# ORDER 1141-vf9w, darwin half (macbookair 2026-09-13).
#
# THE NINTH IDIOM CLASS, and it is why a flag-shaped advisory never found this:
# ABSENT-ON-DARWIN PRIMITIVES. 1135-z8gn's advisory hunts GNU-vs-BSD FLAG
# differences — `stat -c`, `sed -i`, `date -d`, `readlink -f` — where both hosts
# have the tool and disagree about its options. `/proc` and `setsid` are not
# that. They do not exist on macOS AT ALL, so there is no flag to normalise and
# no invocation to rewrite; the code is simply addressing a kernel interface the
# platform does not have. A grep for idiom flags returns clean on this file.
#
# The trap it set is worth naming, because the author of this file was being
# careful about darwin: the header above chooses `read -r -d ''` over `mapfile`
# BECAUSE macOS ships bash 3.2, and records that check-bash-dialect refused the
# file once and "earned its keep". Every one of those statements is true. The
# dialect guard checks the SHELL, and had nothing to say about a FILESYSTEM that
# is absent on the target. Passing every dialect check is not the same as being
# portable.
#
# MEASURED on tlatoanis-macbook-air (Apple M5, macOS 25.6.0) 2026-09-13:
# `ls -d /proc` -> No such file or directory, and the glob `/proc/[0-9]*` does
# not expand. Before this guard `tillandsias_marked_pids` therefore returned
# EMPTY and `tillandsias_reap_marked` returned 0 having killed nothing — the
# reaper reported success on every darwin host while providing none of the
# protection this order exists to provide. That is a FAIL-OPEN, which is the one
# outcome a termination-propagation guard must never have.
#
# WHAT IS NOT FIXED HERE, deliberately: darwin still has no working reaper. The
# real design cannot be an environment marker at all — macOS cannot read another
# process's environ without entitlements, so `/proc/<pid>/environ` has no darwin
# equivalent to port to. A token FILE or a process GROUP is the shape that can
# work. That is a design decision for this order's author and is filed as a
# child packet rather than guessed at here. This change converts a silent lie
# into a named refusal; it does not make darwin supported.
tillandsias_dispatch_reap_supported() {
    # THE SEAM IS HERE SO THE REFUSAL CAN BE FALSIFIED ON EVERY HOST (yoga,
    # 2026-09-13). Hardcoding `[ -d /proc ]` made the unsupported arm
    # UNREACHABLE on Linux: the one arm that exists because of a substrate
    # difference was the one no other substrate could pin, so every Linux host
    # ran a guard it could never see fire. A guard that cannot fire is
    # indistinguishable from a guard that passes — which is the same class this
    # whole order is about, one level up from the reaper itself.
    #
    # PRODUCTION NEVER SETS THIS. The default is /proc and the variable exists
    # for fixtures, which point it at an empty directory to reproduce a
    # darwin-shaped absence on a host that has /proc. That is not a
    # simulation of macOS — macOS additionally has no way to read another
    # process's environ at all (1145-iigx) — it is a way to prove THIS
    # function's refusal path executes and says what it claims.
    #
    # Yoga's equivalent arm on their detector is what caught a production false
    # positive afterwards, which is the argument for paying the one variable.
    [ -d "${TILLANDSIAS_DISPATCH_PROC_ROOT:-/proc}" ]
}

tillandsias_marked_pids() {
    local token="$1" d pid needle e
    if ! tillandsias_dispatch_reap_supported; then
        echo "unsupported:dispatch-reap:no-proc" >&2
        return 2
    fi
    [ -n "$token" ] || return 0
    needle="TILLANDSIAS_WRAPPER_TOKEN=$token"
    for d in /proc/[0-9]*; do
        pid="${d#/proc/}"
        [ "$pid" = "$$" ] && continue
        [ -r "$d/environ" ] || continue
        {
            while IFS= read -r -d '' e; do
                if [ "$e" = "$needle" ]; then
                    printf '%s\n' "$pid"
                    break
                fi
            done < "$d/environ"
        } 2>/dev/null
    done
}

tillandsias_reap_marked() {
    local token="$1" grace="${2:-20}" pids i left
    # ORDER 1141-vf9w (darwin). NON-ZERO AND LOUD, never a quiet 0. The caller
    # in scripts/with-tillandsias-builder.sh runs this from a
    # `trap '... ; exit 143' TERM INT HUP`, so the status is not consumed as
    # control flow there — which makes the STDERR line the part that carries
    # the information, and is why it must not be suppressed. The distinction
    # this preserves is the whole point: "nothing was reaped because nothing
    # was running" (0, the normal path, arm 8) and "nothing was reaped because
    # this platform cannot reap" (2) were the SAME answer before, and they
    # require opposite responses.
    if ! tillandsias_dispatch_reap_supported; then
        echo "unsupported:dispatch-reap:no-proc — nothing was reaped; a cancelled dispatch may survive on this host (1141-vf9w)" >&2
        return 2
    fi
    pids="$(tillandsias_marked_pids "$token")"
    if [ -z "$pids" ]; then
        return 0
    fi
    echo "[dispatch-reap] propagating termination to the marked tree (1141-vf9w)" >&2
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    for ((i = 0; i < grace; i++)); do
        left="$(tillandsias_marked_pids "$token")"
        [ -n "$left" ] || return 0
        sleep 0.25
    done
    left="$(tillandsias_marked_pids "$token")"
    if [ -n "$left" ]; then
        echo "[dispatch-reap] SIGTERM did not reap it; SIGKILL (1141-vf9w)" >&2
        # shellcheck disable=SC2086
        kill -KILL $left 2>/dev/null || true
        sleep 0.5
        left="$(tillandsias_marked_pids "$token")"
        [ -z "$left" ] || return 1
    fi
    return 0
}
