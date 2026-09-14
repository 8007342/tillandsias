#!/usr/bin/env bash
# ORDER 1079-qb8k. Is the plan binary this host INVOKES current with the fleet?
#
# REWRITTEN 2026-09-06, and the previous version is the reason. It probed for
# ONE commit — yoga's 1079-qb8k claim refusal — and printed
# `ok:plan-binary-current`, a verdict naming the general property on the
# evidence of a single instance. macneo's host PASSED it while its
# `expire-claims --list-live` demonstrably mutated a ledger, because that is a
# different commit (b98f2f9a7) which the probe never touched. It ran correctly
# and measured the wrong thing, which is the harder failure: every hallmark of
# a working check was present.
#
# WORSE, IT WOULD HAVE BEEN ACTIVELY MISLEADING IF WIRED. On 2026-09-05 this
# host's own stale binary carried the claim refusal and lacked b98f2f9a7, so a
# wired guard would have printed `ok:plan-binary-current` on the exact artefact
# that produced a false accusation against another host — a green to cite while
# being wrong. An unwired guard is inert; a wired guard answering a narrower
# question than its NAME is worse, because it produces citations. The path
# existing is necessary and not sufficient: the artefact at the end of it must
# answer the question the path is named for (macneo, 1086-kx8i).
#
# SO IT NO LONGER PROXIES A COMMIT. It delegates to the two-sided fixture,
# which has 16 arms, a known pre-fix signature of 5/16, and seeds its own tree
# under --index so it is safe to run a WRITE-CAPABLE binary in order to find
# out whether it writes.
#
# AND IT REFUSES TO SCORE A BINARY IT COULD NOT EXECUTE (esmeraldinha). On a
# Windows host `./build.sh --check` re-execs into WSL, which cannot execute a
# `.exe` at all: eleven arms then fail with `Exec format error` and the result
# reads 5/16 for a binary that is fine. `cannot execute` and `writes when asked
# to read` MUST NOT produce the same verdict, so executability is probed first
# and a negative is `unmeasured:`, never a refusal.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
FIXTURE="scripts/test-expire-claims-write-is-opt-in.sh"
[ -f "$FIXTURE" ] || { echo "blocked:plan-binary-current:no-fixture:$FIXTURE"; exit 1; }

# THE PRECONDITION, REPORTED AND NEVER INFERRED (macneo). Neither this check
# nor a build-id comparison certifies that what you INVOKED came from the
# checkout. "Does a second copy exist, and does a bare name resolve" is the
# condition under which either means anything, so it is stated in the verdict.
_path_copy="$(command -v tillandsias-plan 2>/dev/null || true)"
_copies="$(type -a tillandsias-plan 2>/dev/null | sed 's/.* is //' | sort -u | grep -c . || true)"
[ -n "${_copies:-}" ] || _copies=0

# Which artefact are we judging? The fixture's own resolution unless a caller
# pins one. An EMPTY `command -v` must not silently become "test the default
# and report it as the installed copy" (macbookair): that is a check whose
# output cannot distinguish "I tested what you named" from "what you named does
# not exist, so I tested something else".
BIN="${TILLANDSIAS_PLAN_BINARY:-}"
if [ -z "$BIN" ]; then
    . scripts/plan-binary-probe.sh 2>/dev/null || true
    if command -v resolve_plan_binary >/dev/null 2>&1; then BIN="$(resolve_plan_binary 2>/dev/null || true)"; fi
fi
[ -n "${BIN:-}" ] || { echo "unmeasured:plan-binary-current:no-binary-resolved copies=$_copies"; exit 0; }

# EXECUTABILITY FIRST, and independent of the fixture's arm semantics. 126 is
# the shell's "found but not executable"; the ENOEXEC text is what WSL prints
# for a PE binary. Either means this locus cannot judge this artefact.
_probe="$("$BIN" build-id 2>&1)"; _prc=$?
case "$_prc:$_probe" in
    126:*|*"Exec format error"*|*"cannot execute binary file"*)
        echo "unmeasured:plan-binary-cannot-execute-here:$BIN rc=$_prc copies=$_copies — this locus cannot run this artefact (a .exe under WSL, or a foreign arch); NOT a staleness verdict"
        exit 0 ;;
esac

# ── ORDER 1152-y3bv: MINT THE PLAN-ONLY LANE'S VALIDATOR-SURFACE STAMP ──────
#
# The pre-push plan-only lane used to judge staleness by comparing the
# resolved binary's mtime against the WHOLE crates/tillandsias-plan tree plus
# the WHOLE workspace Cargo.lock (plan_binary_is_stale,
# scripts/plan-binary-probe.sh). esme measured 2026-09-14 that ANY Cargo.lock
# change anywhere in the workspace re-arms it — three ~2m22s
# `cargo build --release -p tillandsias-plan` rebuilds in one cycle on a
# floor host, none of which touched a byte the lane's own validation reads.
#
# THE FIX NARROWS staleness to the VALIDATOR SURFACE — the sources that
# implement validate-yaml, check --strict-fragments and the fragment
# checkers — but narrowing needs a build-time RECORD to compare against, and
# "the binary records nothing today": neither scripts/cycle-preflight.sh nor
# scripts/plan-binary-probe.sh writes one; both only rebuild or resolve.
#
# THIS STEP IS WHERE THAT RECORD GETS MINTED. It already runs after any build
# this host has done, as part of `./build.sh --check` (gate step
# 095-1079-qb8k), and it has already resolved and executed $BIN above (the
# executability probe).
#
# GATED ON THE OLD, BROADER mtime CHECK — DELIBERATELY. This step cannot
# prove $BIN was JUST compiled; all it can prove is "nothing under
# crates/tillandsias-plan or Cargo.lock is newer than $BIN", which is
# plan_binary_is_stale's own question. When that says fresh, the NARROWER
# validator-surface subset is certainly also current — a subset of a
# not-newer set cannot itself be newer — so it is safe to record its hash as
# the build-time baseline. When the old check says stale, this step changes
# nothing: the last confirmed-fresh stamp (if any) is left standing rather
# than being overwritten on an assumption.
#
# DUPLICATED FROM scripts/hooks/pre-push-local-gate.sh, not shared: 1152-y3bv's
# owned-files list has no library file in scope for one copy, and
# plan-binary-probe.sh belongs to a different packet's concurrent edit. Keep
# the two hash computations in lockstep — scripts/test-plan-only-lane-structural.sh
# pins that they agree on the same input.
if ! command -v plan_binary_is_stale >/dev/null 2>&1; then
    . scripts/plan-binary-probe.sh 2>/dev/null || true
fi
_vs_surface_files() {
    grep -ln 'validate-yaml\|strict-fragments\|declared-closures-check\|closure-evidence-check' \
        crates/tillandsias-plan/src/*.rs 2>/dev/null
    [ -f crates/tillandsias-plan/Cargo.toml ] && echo crates/tillandsias-plan/Cargo.toml
    return 0
}
_vs_surface_lock_stanzas() {
    [ -f Cargo.lock ] || return 0
    local _dep
    for _dep in serde serde_yaml serde_json tillandsias-podman mlua tokio chrono; do
        awk -v want="$_dep" '
            /^\[\[package\]\]/ {
                if (keep) printf "%s", blk
                blk = $0 "\n"; keep = 0
                next
            }
            { blk = blk $0 "\n" }
            $0 == "name = \"" want "\"" { keep = 1 }
            END { if (keep) printf "%s", blk }
        ' Cargo.lock 2>/dev/null
    done
}
_vs_surface_hash() {
    local _sha1 _sha2 _f _list
    if command -v sha256sum >/dev/null 2>&1; then
        _sha1=sha256sum; _sha2=""
    elif command -v shasum >/dev/null 2>&1; then
        _sha1=shasum; _sha2="-a 256"
    else
        return 1
    fi
    _list="$(_vs_surface_files)"
    [ -n "$_list" ] || return 1
    {
        printf '%s\n' "$_list" | while IFS= read -r _f; do
            [ -n "$_f" ] || continue
            printf '%s\n' "$_f"
            cat "$_f" 2>/dev/null
            printf '\000'
        done
        _vs_surface_lock_stanzas
    } | $_sha1 $_sha2 2>/dev/null | cut -d' ' -f1
}
if command -v plan_binary_is_stale >/dev/null 2>&1 && ! plan_binary_is_stale "$BIN"; then
    _vs_new="$(_vs_surface_hash)"
    if [ -n "$_vs_new" ]; then
        _vs_stamp="${BIN}.validator-surface-sha256"
        _vs_tmp="$(mktemp "${_vs_stamp}.XXXXXX" 2>/dev/null || true)"
        if [ -n "$_vs_tmp" ]; then
            if printf '%s\n' "$_vs_new" > "$_vs_tmp" 2>/dev/null && mv -f "$_vs_tmp" "$_vs_stamp" 2>/dev/null; then
                echo "stamped:plan-binary-validator-surface:$_vs_stamp" >&2
            else
                rm -f "$_vs_tmp" 2>/dev/null || true
            fi
        fi
    fi
fi

# The real ledger must be untouched whatever happens. The fixture seeds its own
# tree, but assert it rather than trusting the comment.
_repo_before="$(ls plan/index.d 2>/dev/null | wc -l | tr -d ' ')"
_out="$(TILLANDSIAS_PLAN_BINARY="$BIN" bash "$FIXTURE" 2>&1)"
_repo_after="$(ls plan/index.d 2>/dev/null | wc -l | tr -d ' ')"
if [ "$_repo_before" != "$_repo_after" ]; then
    echo "blocked:plan-binary-current:probe-had-side-effects plan/index.d $_repo_before -> $_repo_after"
    exit 1
fi

_arms="$(printf '%s' "$_out" | sed -n 's/^expire-claims-write-is-opt-in: \([0-9]*\) passed, \([0-9]*\) failed$/\1\/\2/p' | tail -1)"
[ -n "$_arms" ] || { echo "unmeasured:plan-binary-current:fixture-printed-no-arm-count:$BIN"; exit 0; }
_pass="${_arms%/*}"; _fail="${_arms#*/}"

if [ "$_fail" = 0 ]; then
    # ── SECOND AXIS: role_satisfies (order 1115-yvrq) ──────────────────────
    #
    # WHY A SECOND AXIS EXISTS AT ALL. This guard probes ONE behaviour and its
    # verdict says so, which is the honesty the 1079-qb8k rewrite bought. But
    # 1115-yvrq shipped a skill change telling every host to pass its PRECISE
    # role (`linux-immutable`, not `linux`), and that instruction is only safe
    # against a current binary. Against the old matcher — which asked whether
    # the packet's requirement CONTAINED the host role — a precise role matches
    # almost nothing: MEASURED on yoga, `--claimable-by linux-immutable`
    # returned 172 rows before the fix and 301 after.
    #
    # So a host that pulls trunk, reads the new skill, and has not rebuilt
    # loses 129 packets SILENTLY. No error, no empty result — just a shorter
    # queue that reads as a quiet ledger. That is the worst available failure
    # shape and it is exactly the interval when an agent is draining work.
    #
    # A scratch ledger, never the real one: two packets differing only in the
    # requirement they state.
    _rw="$(mktemp -d)"
    mkdir -p "$_rw/plan/index.d"
    {
        printf 'plan_index:\n  version: v1\n  root: plan/\n  steps:\n'
        printf '    - packet_id: needs-platform\n      order: 900-plat\n      title: "t"\n      status: ready\n      kind: fix\n      pickup_role: linux\n      depends_on: []\n'
        printf '    - packet_id: needs-mutable\n      order: 900-mut\n      title: "t"\n      status: ready\n      kind: fix\n      pickup_role: linux-mutable\n      depends_on: []\n'
    } > "$_rw/plan/index.yaml"
    _rows="$("$BIN" --index "$_rw/plan/index.yaml" select-rows --status ready \
        --claimable-by linux-immutable --limit 50 2>/dev/null)"
    rm -rf "$_rw"

    # THE SPECIFIC SATISFIES THE GENERAL: an immutable host must be offered the
    # platform packet. This is the arm a stale binary fails — it returns
    # NEITHER row, because "linux-immutable" is not a substring of "linux".
    case "$_rows" in
        *needs-platform*) : ;;
        *)
            echo "stale:plan-binary-role-matcher-inverted:$BIN copies=$_copies" >&2
            {
                echo "  This binary does not offer a platform-scoped packet to a host"
                echo "  declaring a precise role. It is matching claimability as"
                echo "  CONTAINMENT rather than SATISFACTION (pre-1115-yvrq)."
                echo "  A host following the current skill — which says to pass"
                echo "  linux-immutable or linux-mutable — silently loses about 129"
                echo "  packets against this binary. Measured on yoga 2026-09-06:"
                echo "  --claimable-by linux-immutable returned 172 rows before the"
                echo "  fix and 301 after."
                echo "  REMEDY: scripts/cycle-preflight.sh in the FOREGROUND, then"
                echo "  re-run this check and report the verdict rather than the word fixed."
            } >&2
            exit 1 ;;
    esac
    # AND THE SIBLING REQUIREMENT IS STILL REFUSED — without this arm the check
    # above is satisfied by a matcher that returns everything.
    case "$_rows" in
        *needs-mutable*)
            echo "stale:plan-binary-offers-mutable-only-work-to-an-immutable-host:$BIN copies=$_copies" >&2
            echo "  A packet requiring linux-mutable was offered to linux-immutable (1115-yvrq)." >&2
            exit 1 ;;
    esac

    echo "ok:plan-binary-write-is-opt-in+role-satisfies:$BIN arms=$_pass/0 copies=$_copies path=${_path_copy:-<none-on-PATH>}"
    exit 0
fi
# 5/16 IS NOT PARTIAL SAFETY. The fixture's own header records that two of its
# passing arms pass pre-fix only because `--write` is an UNKNOWN FLAG there.
echo "stale:plan-binary-writes-when-asked-to-read:$BIN arms=$_pass passed/$_fail failed copies=$_copies" >&2
echo "  REMEDY: scripts/cycle-preflight.sh (rebuilds AND installs; runs the binary before replacing the copy on PATH, order 1060-wxdh), then re-run this check and report the ARM COUNT rather than the word fixed." >&2
echo "  Run cycle-preflight in the FOREGROUND: backgrounded through a harness it has produced zero bytes, exit 0, and no rebuild (esmeraldinha, 2026-09-06)." >&2
exit 1
