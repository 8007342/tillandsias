#!/usr/bin/env bash
# ORDER 914-ahsy — build a PATH that genuinely lacks a named tool, so a
# tool-less host can be measured on a host that has the tool.
#
# WHY THIS IS A LIB AND NOT FOUR LINES IN A FIXTURE. Every exit criterion on
# 914-ahsy asks for a MEASURED jq-less path, and this construction is the part
# 799-tb7q's own notes flagged as fiddly. Three constructions look right and are
# not, all three measured:
#
#   * PATH="$W/emptybin" alone — /usr/bin still carries jq via the caller's
#     inherited environment in some shells, and the fixture silently measures
#     the WITH-tool case while reporting the without. The first draft of
#     test-shipped-diagnostic-tool-dispatch.sh did exactly this and reported a
#     formatted PASS from a run that was supposed to have no parser.
#   * a non-executable shadow earlier on PATH — `command -v` SKIPS it.
#   * deleting the binary — on Silverblue /usr is read-only, and where it is
#     not, the tool re-provisions.
#
# The only honest construction is a CURATED bin directory: symlink in
# everything the script under test legitimately needs, and nothing it must not
# find. Generalized from the proven copy in
# scripts/test-shipped-diagnostic-tool-dispatch.sh.
#
# A NOTE ON WHAT THIS CANNOT DO, because overstating it would defeat the point.
# PATH governs which BINARIES are found. It does NOT govern shared-library
# resolution: on a host with jq installed, /usr/lib64/libjq.so.1 remains
# present no matter what PATH says. So a materialization measured here proves
# the extraction and the private-loader path work; it does NOT prove the host
# lacks the libraries. That is why materialize_tool copies the library closure
# and runs under a private LD_LIBRARY_PATH rather than relying on the host —
# and why its verification asserts, via ldd, that the PRIVATE copies are the
# ones loaded. Read that assertion as the real evidence; read this PATH as the
# thing that stops the host binary being silently used instead.
#
# SOURCED, NOT EXECUTED. BASH 3.2 CLEAN.

# The utilities a shell script may legitimately need. Deliberately a LIST and
# not "everything in /usr/bin minus the tool": an allow-list fails closed, so a
# tool nobody thought about is absent rather than silently present.
_NTP_BASE_UTILS="bash sh env printf echo grep egrep sed awk cat cut tr head tail
sort uniq wc dirname basename mktemp rm rmdir mkdir cp mv ln chmod test true false
uname date sleep find xargs tee readlink realpath od stat seq expr timeout"

# _ntp_binpath <name> — the absolute path of the BINARY named <name>, or 1.
#
# NOT `command -v`, and this is a bug I shipped and then caught with this very
# fixture rather than by reading it. `command -v` answers for shell FUNCTIONS,
# aliases and builtins too, and returns the bare name when it does. The agent
# session that wrote this file had a `grep` function in its environment, so
# `command -v grep` printed `grep`, and `ln -sf grep "$dir/grep"` created a
# SELF-REFERENTIAL DANGLING SYMLINK. The curated PATH then had a `grep` entry
# that could not execute, every consumer inside it died with "grep: command not
# found", and the arm reported the tool-less path as unusable — a fixture
# failing for a reason that had nothing to do with its subject.
#
# The lesson generalizes past this file: a harness that builds an environment
# must resolve BINARIES, never commands, because the environment it inherits is
# allowed to have anything of the same name.
# _ntp_sanitized_path — PATH with the litmus runner's shim directory removed.
#
# THE SECOND ENVIRONMENT BUG THIS FILE PAID FOR, and it only appears when the
# fixture runs under scripts/run-litmus-test.sh rather than by hand.
#
# That runner prepends target/litmus-runtime/bin, which holds a `podman`
# WRAPPER (and a materialized `yq`). `toolbox` shells out to podman. So a
# curated bin built while the wrapper is ahead on PATH symlinks the WRAPPER as
# its podman, every `toolbox run` inside the curated environment fails, and
# materialization silently degrades to per-call dispatch — the fixture then
# reports "the mechanism is not working" against code that is fine.
#
# Measured exactly that way: standalone the suite was 8/8 green; under the
# runner four arms failed, with the timing arm reporting 141261 ms vs 141130 ms
# because BOTH paths had been reduced to the same broken fallback.
#
# run-litmus-test.sh documents this hazard about its own ordering ("with the
# wrapper ahead of the real binary the extraction fails silently"). It is the
# same trap one level out: a harness that builds an environment must resolve
# tools against the REAL PATH, not against whatever a parent harness has
# already shimmed.
_ntp_sanitized_path() {
    _ntps_out=""; _ntps_ifs="$IFS"; IFS=:
    for _ntps_d in $PATH; do
        case "$_ntps_d" in
            */target/litmus-runtime/bin|*/target/tool-cache/*) continue ;;
        esac
        [ -n "$_ntps_d" ] || continue
        if [ -z "$_ntps_out" ]; then _ntps_out="$_ntps_d"; else _ntps_out="$_ntps_out:$_ntps_d"; fi
    done
    IFS="$_ntps_ifs"
    printf '%s' "$_ntps_out"
}

_ntp_binpath() {
    _ntpb_p="$(PATH="$(_ntp_sanitized_path)" type -P "$1" 2>/dev/null)" || return 1
    case "$_ntpb_p" in
        /*) printf '%s' "$_ntpb_p"; return 0 ;;
        *)  return 1 ;;
    esac
}

# make_no_tool_path <dir> <tool-to-omit>... [--with <extra-tool>...]
#
# Populates <dir> as a curated bin directory and echoes it. Everything in
# _NTP_BASE_UTILS plus any --with tools is symlinked in; every tool named
# before --with is omitted even if it would otherwise be included.
#
# Returns 1 if the omission does not hold — a fixture whose environment does
# not satisfy its own precondition cannot fail for the right reason, so this
# refuses rather than letting the caller measure the wrong thing.
make_no_tool_path() {
    _ntp_dir="${1:?make_no_tool_path: target dir required}"; shift
    _ntp_omit=""; _ntp_extra=""; _ntp_mode=omit
    for _ntp_a in "$@"; do
        if [ "$_ntp_a" = "--with" ]; then _ntp_mode=extra; continue; fi
        if [ "$_ntp_mode" = omit ]; then _ntp_omit="$_ntp_omit $_ntp_a"
        else _ntp_extra="$_ntp_extra $_ntp_a"; fi
    done

    mkdir -p "$_ntp_dir" || return 1
    for _ntp_t in $_NTP_BASE_UTILS $_ntp_extra; do
        case " $_ntp_omit " in *" $_ntp_t "*) continue ;; esac
        _ntp_p="$(_ntp_binpath "$_ntp_t")" || continue
        ln -sf "$_ntp_p" "$_ntp_dir/$_ntp_t" 2>/dev/null || true
    done

    # ASSERT THE PRECONDITION rather than assuming it.
    for _ntp_t in $_ntp_omit; do
        # `env -i` so the assertion cannot be satisfied — or defeated — by a
        # function or alias inherited from the calling shell. Same lesson as
        # _ntp_binpath: assert against the ENVIRONMENT, not this shell's view.
        if env -i PATH="$_ntp_dir" sh -c "command -v '$_ntp_t'" >/dev/null 2>&1; then
            echo "make_no_tool_path: '$_ntp_t' is STILL reachable on the curated PATH" >&2
            return 1
        fi
    done
    printf '%s' "$_ntp_dir"
}
