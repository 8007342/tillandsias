#!/usr/bin/env bash
# @trace order:1174-u5wp
# @trace order:1056-5344 (the union debt that vetoes adoption)
#
# REGIME: the DECISION block, extracted from the shipped tool by markers and
# driven under the tool's own shell options, against a stubbed gate-stamp.sh.
# No arm runs a gate, pushes anything, or invokes land-on-platform-branch.sh —
# a fixture that ran the land tool to prove the land tool skips a gate would
# take 41 minutes to answer and would push to the fleet's trunk.
#
# DRIVEN UNDER `set -uo pipefail`, the tool's OWN regime, not the fixture's.
# 1175-wuwr was exactly this mistake one file over: a consumer fixture drove an
# extracted block under `set +e` and could not see that the shipped options
# killed the shell at the capture. An extracted block tested under options the
# shipped script does not use is a test of a shell nobody runs.
#
# NO ABSOLUTE TIMESTAMP IS ENCODED HERE. The planted stamp carries a `stamped`
# line because the format has one and an arm asserts it is echoed back; no arm
# compares it to now.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/scripts/land-on-platform-branch.sh"
[ -f "$TOOL" ] || { echo "could-not-run:land-adopts-stamp:missing-tool"; exit 3; }

pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/land-adopt.XXXXXX")" || exit 3
trap 'rm -rf "$W"' EXIT

# EXTRACT BY MARKERS, and fail by name if the extraction finds nothing — an
# empty block would let every arm below "pass" against no code at all.
sed -n '/^    _adopted=""$/,/^    fi$/p' "$TOOL" > "$W/block.sh"
if [ ! -s "$W/block.sh" ]; then
    echo "could-not-run:land-adopts-stamp:extraction-empty (the markers moved; this fixture asserts nothing until they are fixed)"
    exit 3
fi

# _drive <union-debt:0|1> <verify-verdict> <scope-verdict>
_drive() {
    local d; d="$(mktemp -d "$W/c.XXXXXX")"
    mkdir -p "$d/scripts" "$d/gitdir"
    printf '#!/usr/bin/env bash\ncase "$1" in\n  verify) echo "%s" ;;\n  scope)  echo "%s" ;;\nesac\n' "$2" "$3" \
        > "$d/scripts/gate-stamp.sh"
    chmod +x "$d/scripts/gate-stamp.sh"
    printf 'version 2\ndigest deadbeef\nscope full\nstamped 2026-01-01T00:00:00Z\n' > "$d/gitdir/tillandsias-gate-stamp"
    : > "$d/um"
    [ "$1" = "1" ] && printf 'a union record\n' > "$d/um"
    # `git rev-parse --absolute-git-dir` is what the block calls for the stamp
    # path; a stub on PATH keeps the arm hermetic and out of any real repo.
    printf '#!/usr/bin/env bash\nif [ "$1" = "rev-parse" ]; then echo "%s"; exit 0; fi\nexit 0\n' "$d/gitdir" > "$d/scripts/git"
    chmod +x "$d/scripts/git"
    ( cd "$d" && PATH="$d/scripts:$PATH" \
        bash -c 'set -uo pipefail; attempt=1; _um="'"$d"'/um"; . "'"$W"'/block.sh"; printf "ADOPTED=[%s]\n" "${_adopted:-}"' 2>&1 )
}

# ── 1. the case the row exists for: green, full-scope, no union debt ────────
out="$(_drive 0 ok:gate-fresh full)"
case "$out" in
    *"ok:land-adopts-valid-stamp:"*) ok "a green full-scope stamp is adopted and the verdict names the token" ;;
    *) bad "the stamp was not adopted: $out" ;;
esac
case "$out" in
    *"ADOPTED=[2026-01-01T00:00:00Z]"*) ok "the adoption NAMES the stamp it adopted, so a skipped gate is distinguishable from one that never ran" ;;
    *) bad "the adopted stamp's time was not carried: $out" ;;
esac

# ── 2. NEGATIVE CONTROL, the load-bearing one: a stamp older than the tree ──
#    `verify` answers stale:tree-changed-since-gate for exactly this, which is
#    the same verdict the pre-push hook would act on. Adoption must not fire.
out="$(_drive 0 stale:tree-changed-since-gate full)"
case "$out" in
    *"ADOPTED=[]"*) ok "NC: a stamp older than the tree is NOT adopted — the gate runs" ;;
    *) bad "NC: a stale stamp was adopted, which would push an un-gated tree: $out" ;;
esac

# ── 3. NEGATIVE CONTROL: a narrower scope is not a full gate ───────────────
#    The hook enforces scope separately, and a scoped stamp can satisfy it for a
#    narrow push while saying nothing about the gate this tool owes.
out="$(_drive 0 ok:gate-fresh scripts,plan)"
case "$out" in
    *"ADOPTED=[]"*) ok "NC: a narrower-scope stamp is NOT adopted" ;;
    *) bad "NC: a partial-scope stamp was adopted as if it were a full gate: $out" ;;
esac

# ── 4. NEGATIVE CONTROL: the union debt VETOES adoption ────────────────────
#    1056-5344 wrote the debt down precisely so a future "skip the gate when
#    nothing changed" shortcut could not silently inherit it. This IS that
#    shortcut, and this arm is the promise that it does not.
out="$(_drive 1 ok:gate-fresh full)"
case "$out" in
    *"ADOPTED=[]"*) ok "NC: un-gated union debt vetoes adoption even on a green full stamp (1056-5344)" ;;
    *) bad "NC: adoption inherited the un-gated union debt — the exact thing 1056-5344 forbade: $out" ;;
esac

# ── 5. the gate invocation is actually SKIPPED, not merely preceded ─────────
#    Source text: an adoption that printed its verdict and then ran the gate
#    anyway would satisfy every arm above and save nothing.
_guarded="$(sed -n '/^    _gate_rc=0$/,/^    fi$/p' "$TOOL")"
if [ -z "$_guarded" ]; then
    bad "could not locate the gate invocation — arm 5 asserted nothing"
elif printf '%s\n' "$_guarded" | /usr/bin/grep -q 'if \[ -z "\$_adopted" \]; then'; then
    ok "the gate invocation is guarded by the adoption, so a skip is a real skip"
else
    bad "the gate runs unconditionally — adoption would announce a saving it does not make"
fi

# ── 6. a refusal path cannot fire on an adopted attempt ────────────────────
#    The failure branch reads $_gate_rc, which stays 0 when nothing ran. Without
#    the guard, an adopted attempt would fall into the gate-failed branch and
#    refuse a landing it had just approved.
if /usr/bin/grep -q 'if \[ -z "\$_adopted" \] && \[ "\$_gate_rc" -ne 0 \]; then' "$TOOL"; then
    ok "the gate-failure branch is scoped to attempts that actually gated"
else
    bad "the gate-failure branch can fire on an adopted attempt"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: land adopts a valid stamp $pass/$total (1174-u5wp)"
    exit 0
fi
echo "FAIL: land adopts a valid stamp $pass/$total (1174-u5wp)"
exit 1
