#!/usr/bin/env bash
# @trace order:1384-ddua
#
# test-pilot-lua-ports.sh — the first two deciders ported to scripts/lua on the
# one runner (1384-bqhy), each .sh deleted in the same commit, and each incident
# class shown UNREPRESENTABLE by a negative arm, not merely avoided. The door's
# port (the row's arm 3) moved to 1520-z95v (coordinator ruling 2026-09-30).
#
# Arms:
#   1 SEAM       check-seam-writers-canonical.lua prints the byte-identical
#                verdict the .sh printed at the parent commit, and keeps it with
#                `set -o pipefail` in force in the caller and a 200,000-line
#                writer file (the two conditions under which the .sh inverted)
#   2 DIALECT    a file with ONE bash-4 builtin line is ONE offender
#                (blocked:bash4-unguarded:1, 1374-4u6i's double count), and an
#                empty population is refused, never read as clean
#   3 SANDBOX    a script reading a path taken from an env var it did NOT
#                declare with `-- @read-env` is refused, and the same read with
#                the declaration succeeds (coordinator ruling, option ii)
#   4 STALE      a plan binary without `script run` makes the gate's Lua decider
#                a loud could-not-run (rc 3), never a pass
#   5 DELETED    both .sh existed at the pinned baseline and are gone, and
#                both .lua are present (no count: see the arm)
#
# Hermetic: scratch under target/plan-scratch; the live tree is only read.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

PLAN="$(. scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || PLAN=""
case "$PLAN" in ./*) PLAN="$ROOT/${PLAN#./}" ;; esac
if [ -z "$PLAN" ] || ! grep -qx script <<<"$("$PLAN" capabilities 2>/dev/null)"; then
    echo "could-not-run:pilot-lua-ports:no-script-runner — build it: cargo build --release -p tillandsias-plan"
    exit 3
fi
# The baseline is a FIXED historical commit, never a moving ref (relay-fix,
# coordinator 2026-10-01). This used to default to origin/linux-next, which was
# right only until the port landed: from land118 on, trunk has no .sh, so
# ARM 1 and ARM 5 failed by construction on every tree, and ci-release went
# red for every relay. 5c419a98f is land118's first parent, the last trunk
# commit that carries both .sh. Override with TILLANDSIAS_PILOT_PARENT.
PARENT="${TILLANDSIAS_PILOT_PARENT:-5c419a98fd245bbeee63f2cf9c70956cbd5e22c9}"
mkdir -p target/plan-scratch
W="$(mktemp -d "$ROOT/target/plan-scratch/pilot-lua.XXXXXX")"; trap 'rm -rf "$W"' EXIT INT TERM

# ── ARM 1: SEAM ────────────────────────────────────────────────────────────
a1_ok=1; a1_why=""
if git cat-file -e "$PARENT:scripts/check-seam-writers-canonical.sh" 2>/dev/null; then
    git show "$PARENT:scripts/check-seam-writers-canonical.sh" > "$W/seam-parent.sh"
    sh_out="$(bash "$W/seam-parent.sh" 2>&1)"; sh_rc=$?
    lua_out="$("$PLAN" script run scripts/lua/check-seam-writers-canonical.lua 2>/dev/null)"; lua_rc=$?
    [ "$sh_out" = "$lua_out" ] && [ "$sh_rc" = "$lua_rc" ] || { a1_ok=0; a1_why="live tree: sh($sh_rc)=[$sh_out] lua($lua_rc)=[$lua_out];"; }
else
    a1_why="parent $PARENT has no .sh to compare against (already landed?);"
fi
mkdir -p "$W/crate/src"
for n in 1 2; do printf 'fn f(){ podman_seam_lock(); unsafe { std::env::set_var("TILLANDSIAS_PODMAN_BIN", "x") }; }\n' > "$W/crate/src/w$n.rs"; done
{ printf 'fn big(){ podman_seam_lock(); unsafe { std::env::set_var("TILLANDSIAS_PODMAN_BIN", "x") }; }\n'
  i=0; while [ "$i" -lt 200000 ]; do printf '// filler line %d\n' "$i"; i=$((i + 1)); done; } > "$W/crate/src/big.rs"
p_out="$(bash -o pipefail -c '"$0" script run "$@"' "$PLAN" scripts/lua/check-seam-writers-canonical.lua "$W/crate/src" 2>/dev/null)"; p_rc=$?
[ "$p_rc" = 0 ] && [ "$p_out" = "ok:seam-writers-canonical:3" ] || { a1_ok=0; a1_why="$a1_why pipefail+200k: rc=$p_rc out=[$p_out];"; }
[ "$a1_ok" = 1 ] && [ -z "$a1_why" ] && ok "ARM 1: seam-writers verdict byte-identical to the parent .sh, and ok:seam-writers-canonical:3 under pipefail with a 200,000-line writer" \
    || bad "ARM 1: $a1_why"

# ── ARM 2: DIALECT ─────────────────────────────────────────────────────────
mkdir -p "$W/d1" "$W/d0"
printf '#!/usr/bin/env bash\nmapfile -t lines < /etc/hostname\n' > "$W/d1/one.sh"
o2="$(TILLANDSIAS_DIALECT_SCAN_DIR="$W/d1" "$PLAN" script run scripts/lua/check-bash-dialect.lua 2>/dev/null)"; r2=$?
o0="$(TILLANDSIAS_DIALECT_SCAN_DIR="$W/d0" "$PLAN" script run scripts/lua/check-bash-dialect.lua 2>/dev/null)"; r0=$?
if [ "$o2" = "blocked:bash4-unguarded:1" ] && [ "$r2" = 1 ] && [ "$o0" = "blocked:bash-dialect:scan-empty" ] && [ "$r0" -ne 0 ]; then
    ok "ARM 2: one bash-4 builtin line is ONE offender (blocked:bash4-unguarded:1), and an empty population is refused (scan-empty), never clean"
else
    bad "ARM 2: one-builtin=[$o2] rc=$r2; empty=[$o0] rc=$r0"
fi

# ── ARM 3: SANDBOX — only a DECLARED env var widens reads ──────────────────
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pilot-outside.XXXXXX")"
printf 'secret-outside-the-repo\n' > "$OUT_DIR/f.txt"
printf -- '-- @env PILOT_DIR\nlocal s = fs.read(env.get("PILOT_DIR") .. "/f.txt")\nverdict.ok("read", #s)\n' > "$W/undeclared.lua"
printf -- '-- @env PILOT_DIR\n-- @read-env PILOT_DIR\nlocal s = fs.read(env.get("PILOT_DIR") .. "/f.txt")\nverdict.ok("read", #s)\n' > "$W/declared.lua"
u_out="$(PILOT_DIR="$OUT_DIR" "$PLAN" script run "$W/undeclared.lua" 2>/dev/null)"; u_rc=$?
d_out="$(PILOT_DIR="$OUT_DIR" "$PLAN" script run "$W/declared.lua" 2>/dev/null)"; d_rc=$?
rm -rf "$OUT_DIR"
if [ "$u_rc" -ne 0 ] && ! grep -q '^ok:' <<<"$u_out" && [ "$d_rc" = 0 ] && [ "$d_out" = "ok:read:24" ]; then
    ok "ARM 3: an undeclared env path outside the repo is refused ($u_out); the same read under -- @read-env succeeds"
else
    bad "ARM 3: undeclared rc=$u_rc out=[$u_out]; declared rc=$d_rc out=[$d_out]"
fi

# ── ARM 4: STALE BINARY — the gate's Lua decider is could-not-run ──────────
printf '#!/usr/bin/env bash\ncase "$1" in capabilities) echo check ;; *) echo "unknown subcommand" >&2; exit 2 ;; esac\n' > "$W/old-plan"
chmod +x "$W/old-plan"
fn="$(awk '/^_run_lua_decider\(\) \{/{p=1} p{print} p&&/^}/{exit}' build.sh)"
o4="$(SCRIPT_DIR="$ROOT" TILLANDSIAS_PLAN_BIN="$W/old-plan" bash -c '_afford() { printf "  why: %s\n  remedy: %s\n" "$1" "$2" >&2; }; _run() { "$@"; }; '"$fn"'; _run_lua_decider scripts/lua/check-bash-dialect.lua' 2>&1)"; r4=$?
if [ "$r4" = 3 ] && grep -q '^could-not-run:lua-decider:check-bash-dialect.lua:no-script-runner' <<<"$o4" && grep -q 'remedy:' <<<"$o4" && ! grep -q '^ok:' <<<"$o4"; then
    ok "ARM 4: with a plan binary lacking script run, the gate's Lua decider is a loud could-not-run (rc 3, why+remedy), never a pass"
else
    bad "ARM 4: rc=$r4 out=[$(tr '\n' '|' <<<"$o4")]"
fi

# ── ARM 5: DELETED ─────────────────────────────────────────────────────────
# Asserts the PORT, not a count. The old arm also wanted scripts/check-*.sh to
# be exactly two fewer than the parent, which held only on the commit that
# landed this row: the next .sh added or retired anywhere moves that number
# (and keeping it from rising is 1384-bxhk's ratchet, not this fixture's job).
a5_why=""
for _n in check-bash-dialect check-seam-writers-canonical; do
    git cat-file -e "$PARENT:scripts/$_n.sh" 2>/dev/null || a5_why="$a5_why $_n.sh absent at the baseline $PARENT (shallow clone, or a wrong pin);"
    [ ! -e "scripts/$_n.sh" ] || a5_why="$a5_why scripts/$_n.sh is back;"
    [ -f "scripts/lua/$_n.lua" ] || a5_why="$a5_why scripts/lua/$_n.lua is missing;"
done
if [ -z "$a5_why" ]; then
    ok "ARM 5: both .sh existed at the baseline and are gone, and both .lua are present"
else
    bad "ARM 5:$a5_why"
fi

echo "pilot-lua-ports: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
