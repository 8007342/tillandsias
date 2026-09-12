#!/usr/bin/env bash
# @trace order:1130-i6xj, spec:ci-release
#
# check-portability-idioms.sh — ADVISORY, COUNTED, NEVER BLOCKING.
#
# Name shell idioms that pass on the host that wrote them and fail somewhere
# else. On 2026-09-12 seven of these landed across three hosts in one night,
# every one green on trunk before it bit, each costing a fleet-wide stall:
#
#   grep -Rl over a symlink farm   GNU descends symlinked dirs, BSD does not —
#                                  five wired guards reported ORPHAN, macOS
#                                  lands refused (1087-h2z9)
#   rg with no path operand        ripgrep reads STDIN when stdin is a readable
#                                  stream, so under a pipe it blocked FOREVER —
#                                  the gate HUNG rather than failing
#   sed -i SCRIPT FILE             GNU-only; BSD takes the next arg as the
#                                  backup suffix, so the edit silently did
#                                  NOTHING and the arm failed itself (1127-waxf)
#   find -printf                   GNU-only; on BSD the set went silently EMPTY
#                                  inside a pre-push HOOK, so a guard stopped
#                                  guarding on the path macOS pushes through
#   touch -d                       GNU-only (1129-4su6)
#   literal "current" timestamp    a fixture with an EXPIRY DATE — see below
#   ugrep/rg installed AS grep     NOT DETECTABLE HERE, see LIMITS
#
# WHY THIS IS ADVISORY AND NOT A GATE. Four of those seven froze a platform.
# A check able to do the same thing to fix them would cost more than it saves,
# and the counted number is the signal: if it climbs, someone looks.
#
# ── SEVERITY, SILENT CLASS FIRST ───────────────────────────────────────────
# Where the idiom sits decides how it fails, and the dangerous half is the
# quiet one:
#   SILENT-DEGRADE  a hook or production script. Fails on the host that
#                   PUSHES, emits nothing, and the wrong answer looks exactly
#                   like the right one.
#   LOUD-FAIL       a fixture. Fails on the host that RUNS it, by name.
#                   Expensive, but self-announcing.
# A tally that mixes them hides the dangerous half behind the noisy one, so
# silent-degrade is counted and printed first.
#
# ── LIMITS, STATED SO NOBODY READS THE COUNT AS COMPLETE ────────────────────
# Two of the seven are NOT source text and this script cannot see them:
#   * a PATH-dependent tool identity — a host with ugrep installed as `grep`
#     runs a script BY HAND and it passes, while the same script under a child
#     bash resolving /usr/bin/grep fails. Same tree, same second, both true.
#   * a locked login keychain — git-credential-osxkeychain answers in a GUI
#     session and hangs forever headless.
# Both are runtime facts. A green run here means "no known idiom in the
# source", never "portable".
#
# Exit: ALWAYS 0. This is an advisory.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 0

# COMMENTS ARE NOT CODE, and skipping them is not cosmetic. Every one of these
# idioms is DISCUSSED in the comments of the file that fixed it —
# audit-guard-activation.sh names `grep -Rl` four times explaining why it no
# longer uses it. A guard that counts those reports four defects in a file that
# is correct, which is the false-accusation shape this repo has been bitten by
# three times (599-w5jd, 1087-h2z9, 823-u5zf). Strip full-line comments before
# matching; an idiom in a trailing comment is rare enough to accept.
# JOIN BACKSLASH CONTINUATIONS BEFORE MATCHING, or every fallback chain that
# wraps reads as an unguarded GNU-ism. Both remaining touch -d hits were
# correct — `touch -d ... \` newline `|| touch -t "$(date -v ...)"` in
# litmus-stdlib.sh, the repo's own sanctioned GNU/BSD absorption layer, and the
# same shape in test-plan-binary-locus-native.sh. Flagging the absorption layer
# for absorbing is the purest form of the false accusation this script must not
# make. The reported line number stays that of the FIRST physical line.
_code_lines() { # _code_lines <file> -> "lineno:joined-text" for non-comment lines
    awk '
        NF && $1 !~ /^#/ {
            if (pending == "") { start = FNR; pending = $0 }
            else { pending = pending " " $0 }
            if (pending ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", pending); next }
            print start ":" pending; pending = ""
        }
        END { if (pending != "") print start ":" pending }
    ' "$1" 2>/dev/null
}

# A LINE CARRYING BOTH DIALECTS IS ALREADY PORTABLE, AND FLAGGING IT IS HOW AN
# ADVISORY BECOMES FURNITURE. The first cut of this script reported 45 hits,
# and the very first one inspected was
#   img_bytes=$(stat -f%z "$IMG" 2>/dev/null || stat -c%s "$IMG" 2>/dev/null || echo 0)
# in diagnose-macos-provision.sh — a correct BSD-first fallback chain, written
# by someone who had already thought about exactly this. A guard that calls
# that a defect trains its readers to scroll past the number, which is the
# 1068-cxmf failure ("a gate line that prints forever with no owner is the one
# everyone learns to read past") and costs more than the defects it finds.
# So: if the counterpart dialect appears on the same line, the author has
# handled it — say nothing.
_has_fallback() { # _has_fallback <line> <counterpart-pattern>
    case "$1" in *"$2"*) return 0 ;; esac
    return 1
}

# Command-position test via grep -E rather than bash's [[ =~ ]]: /bin/bash is
# 3.2 on the macOS hosts and its regex engine chokes on the escaped `$(` this
# needs. Using the tool that is good at regex, from the script about not
# assuming your tool is the other one's.
_rg_in_command_position() { # _rg_in_command_position <line>
    printf '%s\n' "$1" | grep -Eq '(^|[|;&(]|\$\()[[:space:]]*(rg|\$RG)[[:space:]]'
}

# A STRING EXECUTED ON A LINUX HOST IS NOT A PORTABILITY DEFECT, and flagging
# one removes a whole CLASS of false positive rather than a line. Measured
# 2026-09-12: with-nix-builder.sh:295 carries `readlink -f` inside
# _NB_POPULATE_SNIPPET, which is appended to a script string and run via
# `podman run "$_NB_IMAGE_NAME" -c "$_script"` (line ~330) — i.e. INSIDE A
# LINUX CONTAINER, where GNU readlink is guaranteed. The idiom is correct
# there and "fixing" it would be churn.
#
# The same applies to anything dispatched through `wsl.exe` or `ssh`: the
# dialect that matters is the REMOTE one, and this scan cannot see it. So a
# line whose idiom sits inside such a dispatch is skipped and SAID to be
# skipped — the guard's own limits section already refuses to let a count read
# as a portability verdict, and this is one more thing it cannot see rather
# than one more thing it knows.
#
# TWO FORMS, because the worked example needs the second. A same-line dispatch
# is easy. But with-nix-builder.sh assigns the snippet at :295 and dispatches it
# at ~:330 — thirty-five lines apart — so a same-line rule flags it anyway,
# which is what the first cut of this did. The variable is the link, so follow
# it: collect the variables that a remote dispatch EXECUTES in this file, then
# skip assignments to those variables.
#
# This is NOT exemption-by-inference. The evidence is a dispatch line in the
# same file naming that exact variable; nothing is skipped on a name that
# merely looks remote. A variable executed remotely from ANOTHER file is still
# flagged, which is the correct side to err on.
_is_remote_context() { # _is_remote_context <line>
    case "$1" in
        *"podman run"*|*"docker run"*|*"wsl.exe"*|*"wsl "*|*"ssh "*|*"--exec-guest"*) return 0 ;;
    esac
    return 1
}

# Variables this file hands to a remote dispatch, TRANSITIVELY — because one
# hop is not enough and the worked example proves it. with-nix-builder.sh runs
# `podman run … -c "$_script"`, and $_script is built from
# $_NB_POPULATE_SNIPPET thirty-five lines earlier. A one-hop rule finds
# $_script and still flags the snippet, which is exactly what the first two
# cuts of this did.
#
# So: seed with the variables a dispatch line names, then repeatedly add any
# variable whose ASSIGNMENT references one already in the set. Each link is a
# real assignment in the same file — evidence, not name-matching — and the
# closure is capped so a pathological file cannot spin. Only files that
# actually contain a dispatch pay for this.
_remote_vars_of() { # _remote_vars_of <file>
    _rv_seed="$(grep -hE 'podman run|docker run|wsl\.exe|wsl |ssh |--exec-guest' "$1" 2>/dev/null \
        | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' | tr -d '${' | sort -u)"
    [ -n "$_rv_seed" ] || { printf ''; return 0; }
    _rv_set="$_rv_seed"
    _rv_i=0
    while [ "$_rv_i" -lt 5 ]; do
        _rv_i=$((_rv_i+1))
        # lines assigning a variable that is IN the set, e.g. `_script+=" … $X"`
        _rv_new="$(
            printf '%s\n' "$_rv_set" | while IFS= read -r v; do
                [ -n "$v" ] || continue
                grep -hE "^[[:space:]]*(local[[:space:]]+)?${v}\+?=" "$1" 2>/dev/null
            done | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' | tr -d '${' | sort -u
        )"
        _rv_merged="$(printf '%s\n%s\n' "$_rv_set" "$_rv_new" | grep -v '^$' | sort -u)"
        [ "$_rv_merged" = "$_rv_set" ] && break
        _rv_set="$_rv_merged"
    done
    printf '%s\n' "$_rv_set"
}

_assigns_remote_var() { # _assigns_remote_var <line> <remote-vars>
    case "$1" in
        [A-Za-z_]*=*) : ;;
        *) return 1 ;;
    esac
    _arv_name="${1%%=*}"
    _arv_name="${_arv_name##*[!A-Za-z0-9_]}"
    [ -n "$_arv_name" ] || return 1
    case "
$2
" in
        *"
$_arv_name
"*) return 0 ;;
    esac
    return 1
}

# AN IDIOM INSIDE AN EXPLICIT DIALECT BRANCH IS ALREADY HANDLED — the third
# false-positive class, and the third time this guard has been wrong in its own
# favour. bump-version.sh:157-161 reads:
#
#   if sed --version 2>/dev/null | grep -q GNU; then
#       sed -i "0,/…/s//…/" "$f"          # GNU arm — FLAGGED by a naive scan
#   else
#       awk … "$f" > tmp && mv tmp "$f"    # BSD arm, with a comment saying
#   fi                                     # "BSD sed: can't use 0,/pat/"
#
# The author had already solved it, in more depth than the guard knows: BSD
# sed also rejects the `0,/re/` ADDRESS, which measured here as a SILENT NO-OP
# (exit 0, file unchanged) — so a naive `-i` fix would have left the real
# defect in place while removing the warning about it.
#
# BOUNDED WINDOW, not file-level: a dialect probe suppresses only the next few
# lines. A file that branches for ONE idiom must not get blanket immunity for
# every other idiom in it — that would be an exemption list wearing a
# heuristic's clothes.
_DIALECT_WINDOW=6

_is_dialect_probe() { # _is_dialect_probe <line>
    case "$1" in
        *"--version"*GNU*|*"grep -q GNU"*|*"grep -qi gnu"*) return 0 ;;
        *"uname -s"*|*"_litmus_os"*|*"Darwin)"*) return 0 ;;
    esac
    return 1
}

_looks_like_invocation() { # _looks_like_invocation <line>
    case "$1" in
        *" -"*|*"'"*|*'"'*) return 0 ;;
    esac
    return 1
}

_class_of() { # _class_of <file> -> silent|loud
    case "$1" in
        */hooks/*|*/pre-push*|*/post-*) echo silent ;;
        */test-*|*/litmus-*) echo loud ;;
        *) echo silent ;;  # a production script is silent-degrade by default
    esac
}

silent_hits=()
loud_hits=()

_flag() { # _flag <file> <lineno> <idiom> <portable form>
    local entry="$1:$2: $3 — $4"
    if [ "$(_class_of "$1")" = "silent" ]; then
        silent_hits+=("$entry")
    else
        loud_hits+=("$entry")
    fi
}

# A literal `touch -t` timestamp is only a bug when it is meant to be NOW.
# Setting a file deliberately OLD is legitimate and common — the freshness
# fixture sets a stub to 2026-09-04 and its source to 2026-09-11 precisely to
# build the stale case it tests, and flagging that would be noise. The
# discriminator is RECENCY: a literal at or after today's date is one someone
# wrote meaning "current", and it stops meaning that the moment the clock
# passes it. That is what expired at 06:00 on 2026-09-12 and refused every land
# on every host.
_today="$(date -u +%Y%m%d)"

while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$f" in */check-portability-idioms.sh) continue ;; esac
    _rvars="$(_remote_vars_of "$f")"
    _dialect_left=0
    while IFS= read -r line; do
        n="${line%%:*}"; t="${line#*:}"
        # Remote dispatch: the dialect that matters is the remote host's,
        # and this scan cannot see it. Same-line dispatch, or an assignment to
        # a variable this file later hands to one.
        _is_remote_context "$t" && continue
        [ -n "$_rvars" ] && _assigns_remote_var "$t" "$_rvars" && continue
        # Inside an explicit GNU/BSD branch: the author is already handling it.
        if _is_dialect_probe "$t"; then _dialect_left=$_DIALECT_WINDOW; fi
        if [ "$_dialect_left" -gt 0 ]; then
            _dialect_left=$((_dialect_left - 1))
            continue
        fi
        case "$t" in
            *"sed -i"*)
                case "$t" in
                    *"sed -i ''"*|*'sed -i ""'*)
                        _flag "$f" "$n" "sed -i '' (BSD-only; GNU eats the empty arg as the SCRIPT)" \
                              "sed EXPR in > tmp && mv tmp in" ;;
                    *) _flag "$f" "$n" "sed -i (GNU-only; BSD reads the next arg as a backup suffix)" \
                              "sed EXPR in > tmp && mv tmp in" ;;
                esac ;;
        esac
        # grep -R/-r ONLY when the target is a known SYMLINK FARM. A bare
        # `grep -R` is fine on ordinary trees and flagging every one would
        # bury the signal; the defect is specifically GNU-descends-symlinks
        # versus BSD-does-not, so it only bites where symlinked dirs are the
        # point. Those paths are enumerable here: the runtime skill dirs.
        case "$t" in
            *"grep -R"*|*"grep -r"*)
                # ONLY the dotted RUNTIME dirs are symlink farms. `skills/` is
                # the CANONICAL tree of real files — grep -r over it is correct,
                # and flagging it called check-plan-ledger-readers.sh:116 a
                # defect for searching the real directory.
                case "$t" in
                    *.claude/*|*.opencode/*|*.codex/*|*.gemini/*|*.github/skills*)
                        _flag "$f" "$n" "grep -R/-r over a symlink farm (BSD does NOT descend symlinked dirs)" \
                              "find -L DIR -type f -print0 | xargs -0 grep -l" ;;
                esac ;;
        esac
        # `rg` with no PATH OPERAND reads STDIN when stdin is a readable
        # stream, and blocks forever under a pipe — the gate HANG, which is
        # worse than a failure because it presents as slowness. Heuristic: an
        # rg invocation whose line has no path-looking final token and no
        # explicit redirect. Deliberately conservative; a missed hang costs
        # less than an advisory nobody reads.
        # ANCHOR THE COMMAND, do not glob for the letters. The first cut
        # matched `*"rg "*`, which hits `forge `, `.org `, `merge ` and any
        # word ending in rg — 171 flags, instantly the furniture this script
        # exists not to become. `rg` must sit in COMMAND POSITION: start of
        # line, or after a pipe, `(`, `;`, `&&`, or a `$(`.
        # HELP TEXT IS NOT AN INVOCATION. `  rg <muster>   Ripgrep (schnelle
        # Suche)` in help-de.sh sits in command position by the regex and is a
        # usage line in a heredoc. A real call carries a flag or a quoted
        # pattern; a usage line carries neither.
        # CHEAP GLOB BEFORE THE FORK. _rg_in_command_position shells out to
        # grep, and calling it for every line of every script cost 102s — an
        # advisory that slow gets disabled, which is the same end state as not
        # writing it (1009-gccx: cheap deciders first). The glob rejects
        # ~everything for free; only survivors pay for a fork.
        case "$t" in *rg*) _rg_maybe=1 ;; *) _rg_maybe=0 ;; esac
        if [ "$_rg_maybe" = 1 ] && _rg_in_command_position "$t" && _looks_like_invocation "$t"; then
            case "$t" in
                *"< /dev/null"*|*"</dev/null"*) : ;;
                *" ."*|*'"$ROOT"'*|*'"$f"'*|*crates*|*scripts*|*plan/*|*openspec*|*images*) : ;;
                *'\') : ;;   # continuation: the path may be on a later line
                *) _flag "$f" "$n" "rg with no path operand (reads STDIN; BLOCKS FOREVER under a pipe)" \
                         "give it an explicit path, e.g. rg PATTERN \"\$ROOT\"" ;;
            esac
        fi
        case "$t" in
            *"find "*"-printf"*)
                _flag "$f" "$n" "find -printf (GNU-only; BSD yields an EMPTY set, silently)" \
                      "find ... -exec stat/basename, or -print0 | xargs -0" ;;
        esac
        case "$t" in
            *"touch -d"*)
                # BSD offers TWO counterparts: an absolute stamp (-t) and a
                # relative adjust (-A). test-plan-binary-locus-native.sh uses
                # `touch -d '+1 hour' || touch -A '0100'`, which is correct and
                # was flagged until -A was recognised. Accept either.
                { _has_fallback "$t" "touch -t" || _has_fallback "$t" "touch -A"; } && : || \
                    _flag "$f" "$n" "touch -d (GNU-only)" "touch -t YYYYMMDDhhmm, or plain touch for now" ;;
        esac
        case "$t" in
            *"touch -t "*)
                stamp="$(printf '%s' "$t" | sed -n 's/.*touch -t \([0-9]\{8\}\)[0-9]*.*/\1/p')"
                if [ -n "$stamp" ] && [ "$stamp" -ge "$_today" ] 2>/dev/null; then
                    _flag "$f" "$n" "touch -t $stamp — a literal at/after today is a fixture with an EXPIRY DATE" \
                          "plain touch (mtime=now) when the file must be CURRENT"
                fi ;;
        esac
        # EIGHTH IDIOM: STRING-COMPARING A wc COUNT. BSD wc PADS — `wc -l`
        # prints "       1" on macOS and "1" on GNU — so `[ "$(… | wc -l)" = 1 ]`
        # is false wherever the padding exists, while `-eq` is right everywhere.
        # This cost a red on every macOS host in
        # litmus-sigpipe-verdict-pipeline-shape.yaml: the enforcer was clean,
        # emitted exactly one verdict line, and the step reported FAIL anyway.
        # The padding is invisible in a diff and the failure accuses the thing
        # being measured rather than the comparison, which is what makes it
        # worth a pattern rather than a code review.
        case "$t" in
            *"wc -l"*|*"wc -c"*|*"wc -w"*)
                case "$t" in
                    # A line that STRIPS the whitespace first is already correct —
                    # spec-index-ensure.sh:524 pipes through `tr -d '[:space:]'`
                    # before comparing, and flagging it would be the same false
                    # accusation as flagging a BSD-first fallback chain.
                    *"tr -d"*|*"tr -s"*) : ;;
                    *'" = '*|*'" != '*|*"\" = "*|*"\" != "*)
                        _flag "$f" "$n" "string-comparing a wc count (BSD PADS: \"       1\" != \"1\")" \
                              "use -eq / -ne, never = / !=" ;;
                esac ;;
        esac
        case "$t" in
            *"readlink -f"*)
                { _has_fallback "$t" "&& pwd" || _has_fallback "$t" "greadlink"; } && : || \
                    _flag "$f" "$n" "readlink -f (GNU-only on older BSD)" "cd \"\$(dirname X)\" && pwd" ;;
        esac
        case "$t" in
            *"date -d "*)
                # THREE BSD COUNTERPARTS, not two. `-r EPOCH` and `-v` are the
                # obvious ones; `date -j` / `-jf FMT` is the BSD PARSE form, and
                # it is what every correct site in this tree actually uses —
                # `date -d "$x" +%s 2>/dev/null || date -jf '%Y-%m-%dT%H:%M:%S' …`.
                # Omitting it made this arm report FOUR correct fallback chains
                # as defects (check-readme-discipline.sh, manage-cache.sh,
                # test-forge-liveness-probe.sh, hooks/pre-commit-openspec.sh),
                # which is the whole `date -d` class minus one deliberate test
                # subject. An incomplete counterpart list does not under-report:
                # it accuses working code.
                { _has_fallback "$t" "date -r" || _has_fallback "$t" "date -v" \
                  || _has_fallback "$t" "date -j"; } && : || \
                    _flag "$f" "$n" "date -d (GNU-only; BSD uses -v/-r)" "date -r EPOCH, or compute in awk" ;;
        esac
        case "$t" in
            *"stat -c"*)
                _has_fallback "$t" "stat -f" && : || \
                    _flag "$f" "$n" "stat -c (GNU-only; BSD uses -f)" "wc -c / a stat wrapper in litmus-stdlib.sh" ;;
        esac
    done < <(_code_lines "$f")
done < <(find -L scripts build.sh -type f -name '*.sh' -o -type f -name 'build.sh' 2>/dev/null | sort -u)

printf 'portability-idioms: silent-degrade=%d loud-fail=%d\n' "${#silent_hits[@]}" "${#loud_hits[@]}"

if [ "${#silent_hits[@]}" -gt 0 ]; then
    echo "  SILENT-DEGRADE (fails on the host that PUSHES, with no error):"
    printf '    %s\n' "${silent_hits[@]}"
fi
if [ "${#loud_hits[@]}" -gt 0 ]; then
    echo "  LOUD-FAIL (fails on the host that RUNS it, by name):"
    printf '    %s\n' "${loud_hits[@]}"
fi

# NOT grep-detectable, restated at the point of the count so the number is
# never mistaken for a portability verdict.
echo "  note: a PATH-dependent tool identity (ugrep/rg installed as grep) and a"
echo "  locked login keychain are RUNTIME facts this scan cannot see."
exit 0
