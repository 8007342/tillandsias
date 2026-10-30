#!/usr/bin/env bash
# @trace order:1916-tsel, order:1916-gbct, spec:ci-release
#
# gate-changed.sh — the warm-forge fast loop behind `./build.sh --changed [base]`.
#
# WHY. `./build.sh --check` runs every cargo test binary and ~430 shell/Lua
# fixtures whatever the change touched: ~24 min, ~21 of them fixtures
# (plan/issues/gate-time-profile-2026-10-29.md). A warm cargo build is 1-3 s.
# This runs ONLY the cargo test targets and fixtures whose inputs intersect
# `git diff <base>`, so a consecutive edit on a warm forge is checked in
# seconds. It is a DEVELOPER loop: the land gate stays `--check`, and the
# release tier (`--ci-full`) is untouched.
#
# THE INPUT MAP IS DERIVED, NEVER STORED. Each run rebuilds it from the tree,
# so it cannot go stale behind a change. Sources:
#   * fixtures: every `_run bash "$SCRIPT_DIR/scripts/…"` and
#     `_run_lua_decider "scripts/lua/…"` inside build.sh's --check block, plus
#     every scripts/gate-steps.d/*.step (STEP_SCRIPT / STEP_LUA).
#   * a fixture's inputs: its own file plus every repo path its text DECLARES
#     (literal paths, `$ROOT/…`, sibling basenames), closed transitively over
#     the scripts it names. A directory or glob is a prefix. A line that scans
#     the tree with no path (`git ls-files`, `grep -r "$ROOT"`, `find "$ROOT"`)
#     makes the fixture run on EVERY change. strace was the preferred tracer
#     and is absent from the builder toolbox (2026-10-29), so these are
#     DECLARED inputs; a read the text does not name is the residual risk, and
#     `--check` before landing remains the authority.
#   * cargo: a changed file under a workspace member selects that crate and
#     every crate that depends on it (reverse path-dependency closure over the
#     members' Cargo.toml); repo paths named in a crate's sources (include_str!,
#     fixtures under scripts/, methodology/) are that crate's inputs too.
#
# FAIL-SAFE. Each of these selects EVERYTHING (exit 10 from --run; build.sh
# then runs the full --check):
#   * a changed GUARD file — build.sh, this script, the shared shell libs, the
#     the workspace manifests/lock/toolchain, and
#     tillandsias-plan plus its dependencies (the plan binary runs every Lua
#     fixture);
#   * a changed path no fixture and no crate maps (an UNMAPPED input);
#   * a population of zero fixtures (the extractor broke, not the tree).
#
# Usage:
#   gate-changed.sh --list [base]   print the selection, run nothing
#   gate-changed.sh --run  [base]   run the selection (build.sh --changed)
#   gate-changed.sh --map           print the derived input map
#   --files <file>                  take the changed paths from a file instead
#                                   of git (used by the replay measurement)
# base defaults to the merge-base of HEAD and origin/linux-next. Changed paths
# are `git diff --name-only <base>` (committed AND uncommitted) plus untracked.
#
# Exit: 0 selection ran green (or --list/--map), 1 a selected check failed,
#       10 everything is selected (run the full gate), 2 usage/could-not-run.
set -uo pipefail

ROOT="${TILLANDSIAS_GATE_CHANGED_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MODE="--list"
BASE=""
FILES_FROM=""
while [ $# -gt 0 ]; do
    case "$1" in
        --list|--run|--map) MODE="$1" ;;
        --files) FILES_FROM="${2:-}"; shift ;;
        -h|--help) sed -n '2,52p' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*) echo "refused:gate-changed:unknown-flag:$1" >&2
            echo "  why: an unknown flag would be read as the base ref and diff against nothing meaningful" >&2
            echo "  remedy: use --list, --run, --map or --files <file>, then an optional base ref (see --help)" >&2
            exit 2 ;;
        *) BASE="$1" ;;
    esac
    shift
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gate-changed.XXXXXX")" || { echo "could-not-run:gate-changed:no-tmpdir"; exit 2; }
[ -n "${GATE_CHANGED_KEEP:-}" ] && echo "work=$WORK" >&2 || trap 'rm -rf "$WORK"' EXIT

cd "$ROOT" || { echo "could-not-run:gate-changed:no-root:$ROOT"; exit 2; }

# ── 1. The repo's file set (tracked + untracked, not ignored) ───────────────
{ git ls-files; git ls-files --others --exclude-standard; } 2>/dev/null | sort -u > "$WORK/files"
[ -s "$WORK/files" ] || { echo "could-not-run:gate-changed:not-a-git-tree:$ROOT"; exit 2; }

# ── 2. The fixture population ───────────────────────────────────────────────
# Lines: id <TAB> runner(bash|lua) <TAB> path <TAB> args <TAB> advisory(0|1|skip=N)
#        <TAB> desc [<TAB> the .step file that wires it — an input of the fixture]
awk '
    /^if \[\[ "\$FLAG_CHECK" == true \]\]; then/ { inchk = 1; next }
    inchk && /^elif \[\[ "\$FLAG_TEST\$FLAG_CHECK/ { inchk = 0 }
    !inchk { next }
    /_step "/ { d = $0; sub(/.*_step "/, "", d); sub(/".*/, "", d); sub(/\.\.\.$/, "", d); desc = d }
    /_run bash "\$SCRIPT_DIR\/scripts\// {
        p = $0; sub(/.*_run bash "\$SCRIPT_DIR\//, "", p)
        rest = p; sub(/^[^"]*"/, "", rest); sub(/".*/, "", p)
        a = rest; sub(/ *2>&1.*/, "", a); sub(/ *(\|\||;|\)|>|\|).*/, "", a); sub(/^ +/, "", a)
        if (a ~ /[$`\\]/) a = ""
        adv = (rest ~ /\|\| *true/) ? 1 : 0
        printf "%s\tbash\t%s\t%s\t%d\t%s\n", p, p, a, adv, desc
    }
    /_run_lua_decider "scripts\/lua\// {
        p = $0; sub(/.*_run_lua_decider "/, "", p); sub(/".*/, "", p)
        printf "%s\tlua\t%s\t\t0\t%s\n", p, p, desc
    }
' build.sh > "$WORK/pop.raw"
for _sf in scripts/gate-steps.d/*.step; do
    [ -e "$_sf" ] || continue
    awk -v sf="$_sf" '
        /^STEP_DESC="/   { d = $0; sub(/^STEP_DESC="/, "", d); sub(/"[^"]*$/, "", d) }
        /^STEP_SCRIPT="/ { p = $0; sub(/^STEP_SCRIPT="/, "", p); sub(/".*/, "", p); r = "bash" }
        /^STEP_LUA="/    { p = $0; sub(/^STEP_LUA="/, "", p); sub(/".*/, "", p); r = "lua" }
        /^STEP_SKIP_EXIT="/ { s = $0; sub(/^STEP_SKIP_EXIT="/, "", s); sub(/".*/, "", s) }
        END { if (p != "") printf "%s\t%s\t%s\t\t%s\t%s\t%s\n", p, r, p, (s == "" ? "0" : "skip=" s), d, sf }
    ' "$_sf"
done >> "$WORK/pop.raw"
# One row per (path,args): the same fixture wired twice runs once.
awk -F'\t' '!seen[$3 "\t" $4]++' "$WORK/pop.raw" > "$WORK/pop"
POP_N="$(wc -l < "$WORK/pop" | tr -d ' ')"

# ── 3. Workspace crates and their path-dependency graph ─────────────────────
awk '/^members *= *\[/ { m = 1; next } m && /\]/ { m = 0 } m { gsub(/[" ,]/, ""); if ($0 != "") print }' Cargo.toml > "$WORK/members"
: > "$WORK/crates"; : > "$WORK/deps"
while IFS= read -r _m; do
    [ -f "$_m/Cargo.toml" ] || continue
    _n="$(awk '/^\[package\]/ { p = 1; next } /^\[/ { p = 0 } p && /^name *=/ { gsub(/.*= *"|".*/, ""); print; exit }' "$_m/Cargo.toml")"
    printf '%s\t%s\n' "$_m" "$_n" >> "$WORK/crates"
    # every `path = "../x"` dependency, whatever the table (normal/dev/build)
    grep -oE 'path *= *"\.\./[^"]+"' "$_m/Cargo.toml" | sed -E 's/.*"\.\.\/([^"]+)"/\1/' |
        while IFS= read -r _d; do printf '%s\tcrates/%s\n' "$_m" "${_d%/}"; done >> "$WORK/deps"
done < "$WORK/members"

# ── 4. Declared inputs: tokens from every script and every crate source ─────
# One grep pass. Token = a run of path characters containing a slash, or a
# script/data basename. The resolver strips leading components ($ROOT/,
# SCRIPT_DIR/, ../) until it names a repo file or directory.
grep -E '\.(sh|lua|awk|py|step)$|^build\.sh$' "$WORK/files" | grep -vE '^crates/' > "$WORK/srcs"
grep -E '^crates/.*\.(rs|toml)$' "$WORK/files" >> "$WORK/srcs"
# shellcheck disable=SC2046
xargs -a "$WORK/srcs" grep -HnE '/|\.(sh|lua|awk|py|yaml|toml|json|txt|tsv|md)' 2>/dev/null |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|--|//)' > "$WORK/tokens" || true
awk -F'\t' -v W="$WORK" '
function add(f, r, t,   k) { k = f SUBSEP r; if (!(k in E) || (E[k] == "r" && t == "x")) E[k] = t }
function dirof(p,   q) { q = p; if (q !~ /\//) return ""; sub(/\/[^\/]*$/, "", q); return q }
function resolve(tok, from,   t, g, i) {
    t = tok
    gsub(/[{}]/, "", t)
    if (t ~ /\*/) {                     # glob -> its static prefix directory
        g = t; sub(/\*.*/, "", g); sub(/[^\/]*$/, "", g); t = g
        if (t == "") return ""
    }
    sub(/\/+$/, "", t)
    for (i = 0; i < 8 && t != ""; i++) {
        if (t in F) return t
        if (t in D) return t "/"
        if (t !~ /\//) break
        sub(/^[^\/]*\//, "", t)
    }
    # a bare basename resolves against the referring file directory
    if (tok !~ /\// && from != "") { t = dirof(from) "/" tok; if (t in F) return t }
    return ""
}
FILENAME == W "/files" { F[$0] = 1; n = split($0, c, "/"); p = ""; for (i = 1; i < n; i++) { p = (p == "" ? c[i] : p "/" c[i]); D[p] = 1 } next }
FILENAME == W "/tokens" {
    line = $0; f = line; sub(/:.*/, "", f); text = line; sub(/^[^:]*:[0-9]+:/, "", text)
    # An EXECUTED or SOURCED script is followed (its inputs become ours); any
    # other named path is a leaf the source reads. Following mere mentions
    # made every fixture reach build.sh and so every script (measured: 347 of
    # 434 units read the whole tree before this split).
    # printf/echo lines are prose about a script, never a run of it.
    ex = (text !~ /(printf|echo|_info|_warn|_error|print\(|error\() / && (text ~ /(^|[[:space:];&|(`"])(bash|sh|source|exec|\.|dofile|loadfile|script run)[[:space:]]/ || text ~ /^[[:space:]]*"?[$]/)) ? "x" : "r"
    full = text; nres = 0
    # A git pathspec after ` -- ` names directories without a slash (crates).
    if (full ~ /git (ls-files|grep)/ && full ~ / -- [A-Za-z]/) {
        ps = full; sub(/.* -- /, "", ps); m = split(ps, w, /[ )"|;]+/)
        for (i = 1; i <= m; i++) if (w[i] in D) { add(f, w[i] "/", "r"); nres++ }
    }
    while (match(text, /[A-Za-z0-9_.@*{}-]*\/[A-Za-z0-9_.\/*@-]+|[A-Za-z0-9_.-]+\.(sh|lua|awk|py|yaml|toml|json|txt|tsv|md)/)) {
        tok = substr(text, RSTART, RLENGTH); text = substr(text, RSTART + RLENGTH)
        r = resolve(tok, f)
        if (r == "" || r == f || r == "/") continue
        nres++
        add(f, r, (ex == "x" && r ~ /\.(sh|lua)$/) ? "x" : "r")
    }
    # TREE SCANS read "*": a repo-wide git listing with no pathspec (not one
    # run inside a scratch repo via -C "$tmp"), a recursive grep/find/rg aimed
    # at the repo root, or a glob over every root entry.
    if (full ~ /git (ls-files|grep)/ && nres == 0 && full !~ /git -C "?[$][{]?[a-z_]/) ALL[f] = 1
    else if (full ~ /(grep -[A-Za-z]*r|find |rg )/ && full ~ /"[$][{]?(ROOT|REPO_ROOT|REPO|TOP|SCRIPT_DIR)[}]?"([ )]|$)/) ALL[f] = 1
    else if (full ~ /"[$][{]?(ROOT|REPO_ROOT|REPO|TOP)[}]?"\/[*]/) ALL[f] = 1
    next
}
FILENAME == W "/scanlines" { f = $0; sub(/:.*/, "", f); ALL[f] = 1; next }
END {
    for (k in E) { split(k, kk, SUBSEP); print kk[1] "\t" kk[2] "\t" E[k] > (W "/edges") }
    ALL["build.sh"] = 1   # a fixture that RUNS build.sh depends on all of it
    for (f in ALL) print f > (W "/allsrc")
}
' "$WORK/files" "$WORK/tokens"
touch "$WORK/edges" "$WORK/allsrc"

# ── 5. Close each fixture and each crate over its inputs ────────────────────
# Output map lines: <unit> <TAB> <input>  where unit is fx:<path>[ args] or
# crate:<dir>, and input is a file, a dir/ prefix, or "*".
awk -F'\t' -v W="$WORK" '
function close_over(start, unit,   q, h, t, cur, n, parts, i, x) {
    delete seen; q[1] = start; h = 1; t = 1; seen[start] = 1
    while (h <= t) {
        cur = q[h++]
        print unit "\t" cur
        if (cur in ALLSRC) print unit "\t*"
        if (!(cur in ADJ)) continue
        n = split(ADJ[cur], parts, "\t")
        for (i = 1; i <= n; i++) {
            x = parts[i]; if (x == "" || (x in seen)) continue
            seen[x] = 1
            # recurse only into scripts this one executes or sources
            if (TY[cur SUBSEP x] == "x") q[++t] = x
            else print unit "\t" x
        }
    }
}
FILENAME == W "/edges"   { ADJ[$1] = ADJ[$1] "\t" $2; TY[$1 SUBSEP $2] = $3; next }
FILENAME == W "/allsrc"  { ALLSRC[$1] = 1; next }
FILENAME == W "/pop"     { u = "fx:" $3 ($4 == "" ? "" : " " $4); close_over($3, u); if ($7 != "") print u "\t" $7; next }
FILENAME == W "/crates"  {
    unit = "crate:" $1
    print unit "\t" $1 "/"
    # a crate reads what its own sources declare outside the crate
    for (s in ADJ) if (index(s, $1 "/") == 1) {
        n = split(ADJ[s], parts, "\t")
        for (i = 1; i <= n; i++) if (parts[i] != "" && index(parts[i], "crates/") != 1) print unit "\t" parts[i]
        if (s in ALLSRC) print unit "\t*"
    }
    next
}
' "$WORK/edges" "$WORK/allsrc" "$WORK/pop" "$WORK/crates" | sort -u > "$WORK/map"

if [ "$MODE" = "--map" ]; then
    cat "$WORK/map"
    exit 0
fi

# ── 6. The changed set ──────────────────────────────────────────────────────
if [ -n "$FILES_FROM" ]; then
    grep -v '^$' "$FILES_FROM" | sort -u > "$WORK/changed"
else
    if [ -z "$BASE" ]; then
        BASE="$(git merge-base HEAD origin/linux-next 2>/dev/null)" || BASE=""
        [ -n "$BASE" ] || { echo "could-not-run:gate-changed:no-base — pass one: ./build.sh --changed <ref>"; exit 2; }
    fi
    git rev-parse --verify -q "$BASE^{commit}" >/dev/null || { echo "could-not-run:gate-changed:bad-base:$BASE"; exit 2; }
    { git diff --name-only "$BASE" --; git ls-files --others --exclude-standard; } 2>/dev/null | sort -u > "$WORK/changed"
fi
CHANGED_N="$(wc -l < "$WORK/changed" | tr -d ' ')"

# ── 7. Guards: these select everything ──────────────────────────────────────
# tillandsias-plan and every crate it depends on: the plan binary runs every
# Lua fixture and most shell guards, so a change there changes them all.
_plan_dir="$(awk -F'\t' '$2 == "tillandsias-plan" { print $1 }' "$WORK/crates")"
awk -F'\t' -v start="$_plan_dir" '
    { A[$1] = A[$1] " " $2 }
    END { q[1] = start; h = 1; t = 1; s[start] = 1
          while (h <= t) { c = q[h++]; print c "/"; n = split(A[c], p, " ")
              for (i = 1; i <= n; i++) if (p[i] != "" && !(p[i] in s)) { s[p[i]] = 1; q[++t] = p[i] } } }
' "$WORK/deps" > "$WORK/plan-closure"
[ -n "$_plan_dir" ] || : > "$WORK/plan-closure"   # no plan crate: nothing to close over
_guard_re='^(build\.sh|scripts/gate-changed\.sh|scripts/ensure_toolbox\.sh|scripts/with-tillandsias-builder\.sh|scripts/timing-log\.sh|scripts/plan-binary-probe\.sh|scripts/cycle-metrics\.sh|scripts/sccache-wrapper\.sh|scripts/lib[^/]*|scripts/[^/]*-lib\.sh|scripts/lua/lib/.*|scripts/gate-steps\.d/[^/]*\.sh|Cargo\.toml|Cargo\.lock|rust-toolchain(\.toml)?|\.cargo/.*|scripts/test-known-red\.txt|scripts/check-test-baseline\.sh)$'

_why_all=""
if [ "$POP_N" -eq 0 ]; then
    _why_all="population-empty (the extractor found no fixtures in build.sh)"
elif [ "$CHANGED_N" -eq 0 ]; then
    echo "ok:gate-changed:no-changes base=${BASE:-files} fixtures=0/$POP_N crates=0"
    exit 0
fi
if [ -z "$_why_all" ]; then
    _g="$(grep -E "$_guard_re" "$WORK/changed" | head -n 1)"
    [ -z "$_g" ] && _g="$(grep -F -f "$WORK/plan-closure" "$WORK/changed" | grep -E '^crates/' | head -n 1)"
    [ -n "$_g" ] && _why_all="guard:$_g"
fi

# ── 8. Intersect ────────────────────────────────────────────────────────────
awk -F'\t' -v W="$WORK" '
FILENAME == W "/changed" { C[$0] = 1; next }
{   unit = $1; inp = $2
    if (inp == "*") { SEL[unit] = "*"; next }
    if (inp ~ /\/$/) { for (c in C) if (index(c, inp) == 1) { SEL[unit] = c; HIT[c] = 1 } }
    else if (inp in C) { SEL[unit] = inp; HIT[inp] = 1 }
}
END {
    for (u in SEL) print "sel\t" u "\t" SEL[u]
    for (c in C) if (!(c in HIT)) print "unmapped\t" c
}' "$WORK/changed" "$WORK/map" > "$WORK/sel"
# "*" fixtures cover every path, so a path is unmapped only if no NAMED input hit it.
_unmapped="$(awk -F'\t' '$1 == "unmapped" { print $2 }' "$WORK/sel" | sort)"
if [ -z "$_why_all" ] && [ -n "$_unmapped" ]; then
    _why_all="unmapped:$(printf '%s' "$_unmapped" | head -n 1) (+$(( $(printf '%s\n' "$_unmapped" | wc -l) - 1 )) more)"
fi

# Crates: selected crates plus their reverse-dependency closure.
awk -F'\t' '$1 == "sel" && $2 ~ /^crate:/ { sub(/^crate:/, "", $2); print $2 }' "$WORK/sel" | sort -u > "$WORK/crate-hit"
awk -F'\t' -v W="$WORK" '
FILENAME == W "/deps" { R[$2] = R[$2] " " $1; next }
{ q[++t] = $0; s[$0] = 1 }
END { h = 1; while (h <= t) { c = q[h++]; print c; n = split(R[c], p, " ")
      for (i = 1; i <= n; i++) if (p[i] != "" && !(p[i] in s)) { s[p[i]] = 1; q[++t] = p[i] } } }
' "$WORK/deps" "$WORK/crate-hit" | sort -u > "$WORK/crate-sel"
awk -F'\t' 'NR == FNR { N[$1] = $2; next } ($0 in N) { print N[$0] }' "$WORK/crates" "$WORK/crate-sel" > "$WORK/pkg-sel"

awk -F'\t' '$1 == "sel" && $2 ~ /^fx:/ { sub(/^fx:/, "", $2); print $2 "\t" $3 }' "$WORK/sel" | sort > "$WORK/fx-sel"
FX_N="$(wc -l < "$WORK/fx-sel" | tr -d ' ')"
PKG_N="$(wc -l < "$WORK/pkg-sel" | tr -d ' ')"
CRATE_TOTAL="$(wc -l < "$WORK/crates" | tr -d ' ')"

if [ -n "$_why_all" ]; then
    echo "select:all reason=$_why_all fixtures=$POP_N/$POP_N crates=$CRATE_TOTAL/$CRATE_TOTAL changed=$CHANGED_N"
    [ "$MODE" = "--run" ] && exit 10
    exit 0
fi

echo "select:scoped fixtures=$FX_N/$POP_N crates=$PKG_N/$CRATE_TOTAL changed=$CHANGED_N base=${BASE:-files}"
while IFS=$'\t' read -r _u _why; do printf 'select:fixture:%s because=%s\n' "$_u" "$_why"; done < "$WORK/fx-sel"
while IFS= read -r _p; do printf 'select:crate:%s\n' "$_p"; done < "$WORK/pkg-sel"
[ "$MODE" = "--run" ] || exit 0

# ── 9. Run the selection ────────────────────────────────────────────────────
_plan=""
_plan="$(. scripts/plan-binary-probe.sh 2>/dev/null && resolve_plan_binary 2>/dev/null)" || _plan=""
case "$_plan" in ./*) _plan="$ROOT/${_plan#./}" ;; esac

# The repo's portable millisecond clock (BSD date prints a literal %3N).
. "$ROOT/scripts/timing-log.sh" 2>/dev/null || true
_now() { if command -v timing_now_ms >/dev/null 2>&1; then timing_now_ms; else echo $(( $(date +%s) * 1000 )); fi; }
_t0="$(_now)"; _fail=0; _ran=0
if [ "$PKG_N" -gt 0 ]; then
    _pk=(); while IFS= read -r _p; do _pk+=(-p "$_p"); done < "$WORK/pkg-sel"
    _tr="$ROOT/target/test-transcript-changed.log"; mkdir -p "$ROOT/target"
    _s="$(_now)"
    cargo test --no-fail-fast "${_pk[@]}" --manifest-path "$ROOT/Cargo.toml" > "$_tr" 2>&1
    _crc=$?
    if ! _v="$(bash scripts/check-test-baseline.sh --from "$_tr")"; then
        tail -n 40 "$_tr"; echo "$_v"; echo "fail:gate-changed:cargo-test rc=$_crc transcript=$_tr"; _fail=$((_fail + 1))
    else
        echo "ok:gate-changed:cargo-test packages=$PKG_N ms=$(( $(_now) - _s ))"
    fi
    # The gate's two feature passes over the headless binary (1074-w7qv,
    # 1713-1dnx) run whenever that crate is selected; same commands as --check.
    if grep -qx tillandsias-headless "$WORK/pkg-sel"; then
        for _feat in "tray,listen-vsock" "listen-vsock guest_feature_set_"; do
            _f="${_feat%% *}"; _flt=""; [ "$_f" = "$_feat" ] || _flt="${_feat#* }"
            _s="$(_now)"; _tr2="$ROOT/target/test-transcript-changed-features.log"
            # shellcheck disable=SC2086
            cargo test -p tillandsias-headless --bin tillandsias --features "$_f" --no-fail-fast \
                --manifest-path "$ROOT/Cargo.toml" -- $_flt --test-threads=1 > "$_tr2" 2>&1
            _crc=$?
            if [ "$_crc" -ne 0 ] && ! bash scripts/check-test-baseline.sh --from "$_tr2" >/dev/null; then
                tail -n 40 "$_tr2"; echo "fail:gate-changed:cargo-test-features:$_f rc=$_crc"; _fail=$((_fail + 1))
            else
                echo "ok:gate-changed:cargo-test-features:$_f ms=$(( $(_now) - _s ))"
            fi
        done
    fi
fi
# TAB IS IFS WHITESPACE: `IFS=$'\t' read` collapses an empty field (most rows
# have no args), shifting every later column, so the row never matched the
# selection and the fixture silently did not run (measured: 3 of 85 selected
# ran). Read through \037, which is not whitespace and keeps empty fields.
cut -f1 "$WORK/fx-sel" > "$WORK/fx-sel.ids"
while IFS=$'\037' read -r _id _runner _path _args _adv _desc _rest; do
    grep -qxF -- "$_id${_args:+ $_args}" "$WORK/fx-sel.ids" || continue
    _ran=$((_ran + 1)); _s="$(_now)"; _out="$WORK/out.$_ran"
    if [ "$_runner" = lua ]; then
        if [ -z "$_plan" ]; then echo "could-not-run:gate-changed:no-plan-binary:$_path"; _fail=$((_fail + 1)); continue; fi
        # shellcheck disable=SC2086
        TILLANDSIAS_SCRIPT_RUNNER_BIN="$_plan" "$_plan" script run "$ROOT/$_path" -- $_args > "$_out" 2>&1 </dev/null
    else
        # shellcheck disable=SC2086
        bash "$ROOT/$_path" $_args > "$_out" 2>&1 </dev/null
    fi
    _rc=$?
    _ms=$(( $(_now) - _s ))
    case "$_adv" in skip=*) [ "$_rc" = "${_adv#skip=}" ] && _rc=0 ;; 1) _rc=0 ;; esac
    if [ "$_rc" -ne 0 ]; then
        tail -n 20 "$_out"; echo "fail:gate-changed:fixture:$_path rc=$_rc ms=$_ms"; _fail=$((_fail + 1))
    else
        echo "ok:gate-changed:fixture:$_path ms=$_ms"
    fi
done < <(tr '\t' '\037' < "$WORK/pop")

_total=$(( $(_now) - _t0 ))
if [ "$_ran" -ne "$FX_N" ]; then
    echo "fail:gate-changed:ran-$_ran-of-$FX_N-selected — a selected fixture did not run"
    echo "  why: the run loop and the selection disagree, so a green here would vouch for fixtures that never ran"
    echo "  remedy: compare --list with this output; fix the population row the loop skipped"
    _fail=$((_fail + 1))
fi
if [ "$_fail" -gt 0 ]; then
    echo "fail:gate-changed:$_fail-failed fixtures=$_ran crates=$PKG_N ms=$_total"
    exit 1
fi
echo "ok:gate-changed fixtures=$_ran crates=$PKG_N ms=$_total"
exit 0
