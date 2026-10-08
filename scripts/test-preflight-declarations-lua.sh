#!/usr/bin/env bash
# @trace order:1553-6b3a, order:1545-qdb5
# preflight: gate-only — its parity arms run the door's sed reader and _pf_predecide twice over every roster guard (~15 s on darwin, measured 2026-10-08)
#
# The door reads each guard's `# preflight: gate-only | gate-only-decider |
# serial` header declaration ONCE per run, through
# scripts/lua/preflight-declarations.lua (one process for the roster), and
# falls back to the host sed (`;}`-closed groups, 1545-qdb5) when no plan
# binary resolves or the reader does not answer. This fixture lifts the door's
# OWN _pf_load_declarations and _pf_predecide out of build.sh and asks them:
#
#   lua      the table path decides every planted guard, and sed is NOT called
#   sed      no plan binary: a note, then the same decisions from the host sed
#   broken   a reader that does not answer: a note, then the same decisions
#   parity   for EVERY guard in the real roster, the Lua rows equal what the
#            fixed sed programs read, and _pf_predecide decides identically
#            with and without the table (the cutover-parity contract)
#
# A negative control (an undeclared guard runs plainly) keeps a broken harness
# from passing as a working reader.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 1
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  [OK]   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  [FAIL] %s\n' "$1"; }
TAB="$(printf '\t')"

fn="$(awk '/^_pf_load_declarations\(\) \{/,/^\}/' build.sh; awk '/^_pf_predecide\(\) \{/,/^\}/' build.sh)"
case "$fn" in
    *"_pf_load_declarations()"*"_pf_predecide()"*) ;;
    *) echo "FAIL: _pf_load_declarations()/_pf_predecide() not found in build.sh — the door's reader moved; re-point this fixture"; exit 1 ;;
esac

PLAN_BIN="$(. scripts/plan-binary-probe.sh 2>/dev/null && resolve_plan_binary 2>/dev/null)" || PLAN_BIN=""
case "$PLAN_BIN" in ./*) PLAN_BIN="$ROOT/${PLAN_BIN#./}" ;; esac
if [ -z "$PLAN_BIN" ]; then
    echo "could-not-run:preflight-declarations-lua:no-plan-binary — cargo build --release -p tillandsias-plan, then re-run"
    exit 3
fi

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/pf-decl-lua.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/scripts/hooks" "$SCRATCH/scripts/lua"
cp scripts/lua/preflight-declarations.lua "$SCRATCH/scripts/lua/"
echo 'bash scripts/check-zz-god-hooked.sh' > "$SCRATCH/scripts/hooks/pre-push.sh"
plant() {  # $1 = path under scratch, remaining = header lines
    local f="$SCRATCH/$1"; shift
    { echo '#!/usr/bin/env bash'; for l in "$@"; do echo "$l"; done; echo 'echo ok'; } > "$f"
}
filler=(); i=0; while [ "$i" -lt 39 ]; do filler+=("# filler $i"); i=$((i+1)); done
plant scripts/test-zz-go.sh          '# preflight: gate-only — drives the litmus runner end to end'
plant scripts/test-zz-hyphen.sh      '# preflight: gate-only - hyphen-led reason'
plant scripts/test-zz-bare.sh        '# preflight: gate-only'
plant scripts/check-zz-go.sh         '# preflight: gate-only — a decider may not'
plant scripts/check-zz-god.sh        '# preflight: gate-only-decider — live synthesis costs seconds per case'
plant scripts/check-zz-god-hooked.sh '# preflight: gate-only-decider — hooked, so ignored'
plant scripts/test-zz-god-only.sh    '# preflight: gate-only-decider — not a gate-only declaration'
plant scripts/test-zz-serial.sh      '# preflight: serial — writes target/release/tillandsias-plan'
plant scripts/test-zz-serial-bare.sh '# preflight: serial'
plant scripts/test-zz-late.sh        "${filler[@]}" '# preflight: gate-only — line 41, past the header'
plant scripts/test-zz-none.sh

# path|rc|stdout the door must produce, whichever reader answered.
EXPECT="scripts/test-zz-go.sh|10|skip:preflight:L:gate-only — drives the litmus runner end to end
scripts/test-zz-hyphen.sh|10|skip:preflight:L:gate-only — hyphen-led reason
scripts/test-zz-bare.sh|0|note:preflight:L:gate-only-without-a-reason — a declaration must name its cost; running it (1496-w25b)
scripts/check-zz-go.sh|0|note:preflight:L:gate-only-ignored — a push decider cannot be gate-only at the door; running it (1496-w25b)
scripts/check-zz-god.sh|10|skip:preflight:L:gate-only — live synthesis costs seconds per case
scripts/check-zz-god-hooked.sh|0|note:preflight:L:gate-only-decider-ignored — a pre-push hook runs it, so the door must too; running it (1518-8p5k)
scripts/test-zz-god-only.sh|0|
scripts/test-zz-serial.sh|12|
scripts/test-zz-serial-bare.sh|0|note:preflight:L:serial-without-a-reason — a declaration must name the shared state; running it concurrently (1499-m9fj)
scripts/test-zz-late.sh|0|
scripts/test-zz-none.sh|0|"
ROSTER="$(printf '%s\n' "$EXPECT" | cut -d'|' -f1)"

# Load the table under a given plan binary, then decide every planted guard in
# the SAME shell (so the table is the one the loader set). sed is shadowed to
# count its calls. Prints the loader's lines, then `D <path>|<rc>|<out>` rows.
run_mode() {  # $1 = root, $2 = plan bin ("" = none)
    ( SCRIPT_DIR="$1"; _pf_plan_bin="$2"
      _preflight_preconditions() { :; }
      sed() { echo x >> "$SCRATCH/sedcalls"; command sed "$@"; }
      eval "$fn"
      printf '%s\n' "$ROSTER" | awk -v t="$TAB" '{ print $0 t "args" }' > "$SCRATCH/roster"
      _pf_load_declarations < "$SCRATCH/roster"
      : > "$SCRATCH/sedcalls"
      while IFS= read -r p; do
          rc=0; out="$(_pf_predecide "$p" L 2>>"$SCRATCH/err")" || rc=$?
          echo "D $p|$rc|$out"
      done <<< "$ROSTER"
      [ -n "${_PF_DECL_TABLE:-}" ] && echo "T yes" || echo "T no"
      echo "S $(wc -l < "$SCRATCH/sedcalls" | tr -d ' ')" )
}
check_decisions() {  # $1 = mode label, $2 = run_mode output
    local miss
    miss="$(printf '%s\n' "$EXPECT" | while IFS= read -r e; do
        grep -qxF "D ${e}" <<< "$2" || echo "$e"; done)"
    if [ -z "$miss" ]; then
        ok "$1: all $(printf '%s\n' "$EXPECT" | wc -l | tr -d ' ') planted guards decided as the door must (rc 10/12/0, every skip/note line)"
    else
        bad "$1: decided differently for: $(printf '%s' "$miss" | head -n 3 | tr '\n' ';') got: $(printf '%s\n' "$2" | grep '^D ' | head -n 12 | tr '\n' ';')"
    fi
}

# --- lua --------------------------------------------------------------------
r="$(run_mode "$SCRATCH" "$PLAN_BIN")"
check_decisions "lua" "$r"
if grep -qx 'T yes' <<< "$r" && grep -qx 'S 0' <<< "$r" && ! grep -q '^note:preflight:declarations' <<< "$r"; then
    ok "lua: the table was loaded by one reader run and _pf_predecide called sed 0 times"
else
    bad "lua: the table path was not the one deciding: $(printf '%s\n' "$r" | grep -E '^(T|S|note:)' | tr '\n' ';')"
fi
rows="$(cd "$SCRATCH" && TILLANDSIAS_REPO_ROOT="$SCRATCH" "$PLAN_BIN" script run "$SCRATCH/scripts/lua/preflight-declarations.lua" -- scripts/test-zz-go.sh scripts/test-zz-bare.sh scripts/test-zz-none.sh scripts/test-zz-absent.sh 2>&1)"
want="scripts/test-zz-go.sh${TAB}gate-only${TAB}drives the litmus runner end to end
scripts/test-zz-bare.sh${TAB}gate-only${TAB}
scripts/test-zz-none.sh${TAB}none${TAB}
scripts/test-zz-absent.sh${TAB}absent${TAB}
ok:preflight-declarations:4"
if [ "$rows" = "$want" ]; then
    ok "lua: the reader prints <path>TAB<kind>TAB<reason> rows (empty reason kept, none/absent named) and its verdict"
else
    bad "lua: reader rows differ: got '$(printf '%s' "$rows" | tr '\t\n' '>;')'"
fi

# --- sed fallback (no plan binary) -------------------------------------------
r="$(run_mode "$SCRATCH" "")"
check_decisions "sed fallback" "$r"
if grep -q '^note:preflight:declarations:host-sed — no plan binary resolves' <<< "$r" && grep -qx 'T no' <<< "$r"; then
    ok "sed fallback: no plan binary is SAID, and the host sed reads the headers (not 'no declarations')"
else
    bad "sed fallback: the no-plan-binary fallback was silent or kept a table: $(printf '%s\n' "$r" | grep -E '^(T|note:)' | tr '\n' ';')"
fi

# --- broken reader -------------------------------------------------------------
cp "$SCRATCH/scripts/lua/preflight-declarations.lua" "$SCRATCH/good.lua"
echo 'error("planted breakage")' > "$SCRATCH/scripts/lua/preflight-declarations.lua"
r="$(run_mode "$SCRATCH" "$PLAN_BIN")"
cp "$SCRATCH/good.lua" "$SCRATCH/scripts/lua/preflight-declarations.lua"
check_decisions "broken reader" "$r"
if grep -q '^note:preflight:declarations:host-sed — scripts/lua/preflight-declarations.lua did not answer' <<< "$r" && grep -qx 'T no' <<< "$r"; then
    ok "broken reader: a reader that does not answer is SAID, and the host sed reads the headers"
else
    bad "broken reader: fell back silently or kept a table: $(printf '%s\n' "$r" | grep -E '^(T|note:)' | tr '\n' ';')"
fi

# --- parity over the real roster ---------------------------------------------
roster_fn="$(awk '/^_preflight_roster\(\) \{/,/^\}/' build.sh)"
real="$( SCRIPT_DIR="$ROOT"; eval "$roster_fn"; _preflight_roster | sort -u | cut -f1 | sort -u )"
paths=""; n=0
while IFS= read -r p; do
    [ -n "$p" ] && [ -f "$ROOT/$p" ] || continue
    paths="$paths$p
"; n=$((n+1))
done <<< "$real"
sed_rows() {  # the fixed (1545-qdb5) sed programs, one path -> rows
    local p="$1" any=""
    if [ -n "$(sed -n '1,40{/^# preflight: gate-only-decider/d;/^# preflight: gate-only/p;}' "$p" | head -n 1)" ]; then
        printf '%s\t%s\t%s\n' "$p" gate-only "$(sed -n '1,40{/^# preflight: gate-only-decider/d;s/^# preflight: gate-only[[:space:]]*//p;}' "$p" | head -n 1 | sed 's/^[—-][[:space:]]*//')"; any=1
    fi
    if [ -n "$(sed -n '1,40{/^# preflight: gate-only-decider/p;}' "$p" | head -n 1)" ]; then
        printf '%s\t%s\t%s\n' "$p" gate-only-decider "$(sed -n '1,40{s/^# preflight: gate-only-decider[[:space:]]*//p;}' "$p" | head -n 1 | sed 's/^[—-][[:space:]]*//')"; any=1
    fi
    if [ -n "$(sed -n '1,40{/^# preflight: serial/p;}' "$p" | head -n 1)" ]; then
        printf '%s\t%s\t%s\n' "$p" serial "$(sed -n '1,40{s/^# preflight: serial[[:space:]]*//p;}' "$p" | head -n 1 | sed 's/^[—-][[:space:]]*//')"; any=1
    fi
    [ -n "$any" ] || printf '%s\tnone\t\n' "$p"
}
want="$(while IFS= read -r p; do [ -n "$p" ] && sed_rows "$p"; done <<< "$paths")"
# shellcheck disable=SC2086
got="$(printf '%s' "$paths" | tr '\n' '\0' | xargs -0 "$PLAN_BIN" script run "$ROOT/scripts/lua/preflight-declarations.lua" -- 2>&1 | grep "$TAB")"
declared="$(printf '%s\n' "$want" | grep -cv "${TAB}none${TAB}")"
if [ "$n" -gt 0 ] && [ "$got" = "$want" ]; then
    ok "parity: for all $n roster guards the Lua rows equal the fixed sed's ($declared declarations)"
else
    bad "parity: Lua and sed disagree over the $n roster guards: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -n 6 | tr '\t\n' '>;')"
fi
table="$got"
dmiss=0; dfirst=""
while IFS= read -r p; do
    [ -n "$p" ] || continue
    a="$( SCRIPT_DIR="$ROOT"; _preflight_preconditions() { :; }; eval "$fn"; _PF_DECL_TABLE="$table"
          rc=0; o="$(_pf_predecide "$p" L 2>/dev/null)" || rc=$?; echo "$rc|$o" )"
    b="$( SCRIPT_DIR="$ROOT"; _preflight_preconditions() { :; }; eval "$fn"; _PF_DECL_TABLE=""
          rc=0; o="$(_pf_predecide "$p" L 2>/dev/null)" || rc=$?; echo "$rc|$o" )"
    if [ "$a" != "$b" ]; then dmiss=$((dmiss+1)); [ -n "$dfirst" ] || dfirst="$p: lua '$a' vs sed '$b'"; fi
done <<< "$paths"
if [ "$dmiss" -eq 0 ]; then
    ok "parity: _pf_predecide decides all $n roster guards identically with the Lua table and with the host sed"
else
    bad "parity: $dmiss roster guard(s) decided differently; first: $dfirst"
fi

# NEGATIVE CONTROL is the test-zz-none.sh row above (rc 0, nothing printed) in
# every mode; here it is asserted on its own so a harness that decides nothing
# cannot pass by matching nothing.
if grep -qx 'D scripts/test-zz-none.sh|0|' <<< "$(run_mode "$SCRATCH" "$PLAN_BIN")"; then
    ok "NEGATIVE CONTROL: an undeclared guard is run (rc 0, nothing printed)"
else
    bad "NEGATIVE CONTROL: an undeclared guard was not run plainly"
fi
if [ -s "$SCRATCH/err" ]; then
    bad "stderr while deciding: $(head -n 1 "$SCRATCH/err")"
fi

echo "preflight-declarations-lua: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "ok:preflight-declarations-lua:$pass"
[ "$fail" -eq 0 ]
