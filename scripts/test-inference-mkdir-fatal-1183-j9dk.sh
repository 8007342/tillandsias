#!/usr/bin/env bash
# ORDER 1183-j9dk. When the inference container cannot create ${OLLAMA_MODELS}.tools
# the entrypoint must fail LOUD AND HERE, naming the ownership that caused it.
#
# WHAT WAS WRONG. The self-install did:
#
#     mkdir -p "$OLLAMA_BINDIR" || echo "[inference] WARN: cannot create ..." >&2
#
# and fell through — sitting directly under a comment reading "Order 313: NO
# error swallowing in this chain". The container still died, but four lines
# later and wearing the wrong face:
#
#     tar: /home/ollama/.ollama/models/.tools: Cannot open: No such file or directory
#     [inference] ollama install FAILED ... will retry next launch (non-fatal)
#     [inference] FATAL: no ollama binary available
#
# "will retry next launch (non-fatal)" immediately followed by "FATAL" describes
# a retry that can never succeed: the cause is a permission structure, not a
# transient. The operator-visible error named a MISSING DIRECTORY rather than the
# reason it was missing, so the macOS occurrence was investigated as a tar/proxy
# problem before the ownership was measured.
#
# REGIME. Arms 1-4 are STATIC over the shipped entrypoint (the subject is what
# the image will do on a host we are not on). Arm 5 is BEHAVIOURAL: it runs the
# shipped guard text against a genuinely unwritable directory. Arm 6 is its
# MUTATION CONTROL — it restores the old `|| echo WARN` form and requires arm 5's
# assertion to go RED, because an assertion that passes on the unfixed code
# proves only that some shell exited.
#
# Prints one PASS/FAIL summary line and exits 0/1.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

pass=0; fail=0
ok()  { echo "ok:   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

EP="images/inference/entrypoint.sh"
[ -f "$EP" ] || { bad "$EP is missing"; echo "inference-mkdir-fatal-1183-j9dk: $pass passed, $fail failed"; exit 1; }

# Code only, captured once. A comment quoting the OLD form to explain what was
# removed must not read as the defect being present (888-m75r), and `grep -c`
# rather than `grep -q` because -q SIGPIPEs its feeder under pipefail (792-ksr8).
_CODE="$(grep -vE '^[[:space:]]*#' "$EP")"
code_has()  { [ "$(printf '%s\n' "$_CODE" | grep -c -- "$1")" -gt 0 ]; }
code_hasE() { [ "$(printf '%s\n' "$_CODE" | grep -cE -- "$1")" -gt 0 ]; }

# ── 1. The swallowing form is gone from LIVE CODE. ─────────────────────────
if code_hasE 'mkdir -p "\$OLLAMA_BINDIR" \|\| echo'; then
    bad "the bindir mkdir still falls through on failure (|| echo WARN)"
else
    ok "the bindir mkdir no longer falls through on failure"
fi

# ── 2. The failure path exits. ────────────────────────────────────────────
if code_hasE 'if ! mkdir -p "\$OLLAMA_BINDIR"; then'; then
    ok "the bindir mkdir failure is handled by an explicit guard"
else
    bad "no 'if ! mkdir -p \$OLLAMA_BINDIR' guard found"
fi

# ── 3. It names ownership, not just a path. ───────────────────────────────
#     uid AND the mount's actual owner: the macOS regime denies the uid at
#     ANY mode, so a message advising only a chmod would misdirect.
_named=0
code_has 'id -u'                 && _named=$((_named + 1))
code_hasE 'ls -ldn "\$OLLAMA_MODELS"' && _named=$((_named + 1))
if [ "$_named" -eq 2 ]; then
    ok "the diagnosis prints the container uid and the mount's owner ($_named/2)"
else
    bad "the diagnosis names ownership only partially ($_named/2 of uid, mount owner)"
fi

# ── 4. Both regimes are cited by order. ───────────────────────────────────
if code_has 'order 313' && code_has '1183-j9dk'; then
    ok "both ownership regimes are cited (Linux volume 313, macOS virtiofs 1183-j9dk)"
else
    bad "the failure path does not cite both the Linux and macOS ownership orders"
fi

# ── 5/6. BEHAVIOURAL + MUTATION CONTROL. ──────────────────────────────────
# Extract the shipped guard and run it for real against an unwritable dir.
_guard="$(sed -n '/^    if ! mkdir -p "\$OLLAMA_BINDIR"; then$/,/^    fi$/p' "$EP")"

# Run the guard; echo the observed exit status. Never let it kill this shell.
_run_guard() {
    # $1 = guard text
    _d="$(mktemp -d)" || return 99
    mkdir -p "$_d/models" || return 99
    chmod 0555 "$_d/models" || return 99
    (
        set -e
        OLLAMA_MODELS="$_d/models/"
        OLLAMA_BINDIR="$_d/models/.tools/ollama"
        export OLLAMA_MODELS OLLAMA_BINDIR
        eval "$1"
    ) >"$_d/out" 2>&1
    _rc=$?
    chmod 0755 "$_d/models" 2>/dev/null || true
    _GUARD_OUT="$(cat "$_d/out" 2>/dev/null)"
    rm -rf "$_d" 2>/dev/null || true
    return $_rc
}

if [ "$(id -u)" = "0" ]; then
    # 0555 is writable by root, so the precondition cannot be created. Refuse
    # rather than pass: a skip that renders as a pass is the whole family of
    # bug this fixture belongs to.
    bad "cannot run the behavioural arms as uid 0 — 0555 does not exclude root, so the unwritable precondition is unconstructible"
elif [ -z "$_guard" ]; then
    bad "could not extract the mkdir guard from $EP — the behavioural arms did not run"
else
    _run_guard "$_guard"; _rc=$?
    if [ "$_rc" -eq 99 ]; then
        bad "could not build the unwritable fixture directory"
    elif [ "$_rc" -eq 0 ]; then
        bad "the guard EXITED 0 on an unwritable models mount — the failure still falls through"
    else
        ok "the guard fails loud on an unwritable models mount (exit $_rc)"
        case "$_GUARD_OUT" in
            *FATAL*) ok "the failure is announced as FATAL where it happens" ;;
            *)       bad "the failure did not announce FATAL (got: $(printf '%s' "$_GUARD_OUT" | head -1))" ;;
        esac
    fi

    # MUTATION CONTROL: restore the swallowing form; arm 5 must go RED.
    _mutant='    mkdir -p "$OLLAMA_BINDIR" || echo "[inference] WARN: cannot create $OLLAMA_BINDIR (volume ownership? see order 313)" >&2'
    if [ "$_mutant" = "$_guard" ]; then
        bad "the mutation is identical to the shipped guard — it did not apply (829-dkuc)"
    else
        _run_guard "$_mutant"; _mrc=$?
        if [ "$_mrc" -eq 99 ]; then
            bad "could not build the unwritable fixture directory for the mutation arm"
        elif [ "$_mrc" -eq 0 ]; then
            ok "mutation control: the old swallowing form exits 0, so arm 5 has teeth"
        else
            bad "mutation control FAILED: the old swallowing form also exited $_mrc, so arm 5 proves nothing"
        fi
    fi
fi

echo "inference-mkdir-fatal-1183-j9dk: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
