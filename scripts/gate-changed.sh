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
# INTAKE (2248-zcqh, bundle landing). `--intake` with --list/--run is the
# light gate a work ref passes to be ACCEPTED onto a lander-owned bundle; the
# bundle's own full gate is the authority that promotes it to linux-next.
# Under --intake:
#   * Rust: the selected crates and their reverse-dep closure run as ONE
#     `cargo nextest run -E 'rdeps(a) | rdeps(b)'` where nextest answers
#     (cargo test -p ... otherwise; the regime is named on a runner: line).
#   * Shell/Lua: fixtures whose derived inputs intersect the diff run in the
#     same pool, EXCEPT whole-tree readers (inputs "*") and fixtures whose
#     header declares `preflight: gate-only — <reason>` (the door's slow list,
#     one declaration for both). Those are DEFERRED to the bundle gate and
#     named on one `deferred:` line, never silently dropped.
#   * a change that cannot be scoped (exit 10 below) prints `heavy:<reason>`
#     and runs nothing: the lander marks the member HEAVY rather than
#     running everything at intake.
#
# CHECKS (2282-asxn, relay-preflight). `--checks` keeps only the selected
# scripts/**/check-* deciders (no test-* fixture, no crate), whole-tree readers
# included: they are the tree-only answers the queue evicts on. A change that
# cannot be scoped selects EVERY check-* decider, never none. A header declaring
# `preflight: gate-only — <reason>` is left out and named on a deferred: line.
#
# Without --intake every line and exit code is exactly today's.
#
# Usage:
#   gate-changed.sh --list [base]   print the selection, run nothing
#   gate-changed.sh --run  [base]   run the selection (build.sh --changed)
#   gate-changed.sh --map           print the derived input map
#   --intake                        the bundle intake gate (see INTAKE above)
#   --check-declared                the decider for declared inputs (2261-8gx5):
#                                   every literal repo file a declaring fixture
#                                   names must be covered by its declaration
#   --checks                        only the check-* deciders (see CHECKS above)
#   --crate-graph                   print the derived path-dependency edges
#                                   (<crate dir> TAB <dep dir>) and exit; the
#                                   metadata lint compares them to cargo's
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
INTAKE=0
CHECKS=0
BASE=""
FILES_FROM=""
while [ $# -gt 0 ]; do
    case "$1" in
        --list|--run|--map|--crate-graph|--check-declared) MODE="$1" ;;
        --intake) INTAKE=1 ;;
        --checks) CHECKS=1 ;;
        --files) FILES_FROM="${2:-}"; shift ;;
        -h|--help) sed -n '2,75p' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*) echo "refused:gate-changed:unknown-flag:$1" >&2
            echo "  why: an unknown flag would be read as the base ref and diff against nothing meaningful" >&2
            echo "  remedy: use --list, --run, --map, --crate-graph, --check-declared, --intake, --checks or --files <file>, then an optional base ref (see --help)" >&2
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
    # every `path = "../x"` dependency, whatever the table (normal/dev/build).
    # A commented-out line is not a dependency (2248-zcqh: host-shell's
    # `# tillandsias-vault-client = { path = ... }` read as one).
    grep -vE '^[[:space:]]*#' "$_m/Cargo.toml" | grep -oE 'path *= *"\.\./[^"]+"' | sed -E 's/.*"\.\.\/([^"]+)"/\1/' |
        while IFS= read -r _d; do printf '%s\tcrates/%s\n' "$_m" "${_d%/}"; done >> "$WORK/deps"
    # 2248-zcqh: `name = { workspace = true }` / `name.workspace = true`
    # resolves through the root [workspace.dependencies] table. The awk above
    # never saw these: 13 of cargo's edges were missing, so a change to
    # tillandsias-core never selected podman, scanner, browser-mcp or vm-layer.
    grep -vE '^[[:space:]]*#' "$_m/Cargo.toml" |
        sed -nE 's/^[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*\{[^}]*workspace[[:space:]]*=[[:space:]]*true.*/\1/p; s/^[[:space:]]*([A-Za-z0-9_-]+)\.workspace[[:space:]]*=[[:space:]]*true.*/\1/p' |
        while IFS= read -r _wn; do
            _wp="$(awk -v n="$_wn" '/^\[workspace\.dependencies\]/ { p = 1; next } /^\[/ { p = 0 }
                p && $1 == n && /path *= *"/ { sub(/.*path *= *"/, ""); sub(/".*/, ""); print; exit }' Cargo.toml)"
            [ -n "$_wp" ] && printf '%s\t%s\n' "$_m" "${_wp%/}"
        done >> "$WORK/deps"
done < "$WORK/members"
sort -u -o "$WORK/deps" "$WORK/deps"
if [ "$MODE" = "--crate-graph" ]; then
    sort -u "$WORK/deps"
    exit 0
fi

# ── 4. Declared inputs: tokens from every script and every crate source ─────
# One grep pass. Token = a run of path characters containing a slash, or a
# script/data basename. The resolver strips leading components ($ROOT/,
# SCRIPT_DIR/, ../) until it names a repo file or directory.
grep -E '\.(sh|lua|awk|py|step)$|^build\.sh$' "$WORK/files" | grep -vE '^crates/' > "$WORK/srcs"
grep -E '^crates/.*\.(rs|toml)$' "$WORK/files" >> "$WORK/srcs"
# shellcheck disable=SC2046
# The list goes on stdin, not via `xargs -a`: BSD xargs has no -a, and with
# stderr discarded the token table came back empty on darwin, so every path
# read unmapped (2056-29t4).
xargs grep -HnE '/|\.(sh|lua|awk|py|yaml|toml|json|txt|tsv|md)' < "$WORK/srcs" 2>/dev/null |
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
    # 2261-8gx5 (1): a shell `case` ARM is a pattern, not a read. Its text up to
    # the arm-closing `)` — `scripts/*|build.sh|flake.nix)` — names paths only to
    # classify one; gate-stamp.sh:174 made all 13 of its executors read the whole
    # scripts/ directory. A function definition `name()` and a subshell `( … )`
    # do not match: the arm text may not contain `(`.
    if (text ~ /^[[:space:]]*[^[:space:];()#]+(\|[^[:space:];()]+)*\)/) sub(/^[[:space:]]*[^[:space:];()#]+(\|[^[:space:];()]+)*\)/, "", text)
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

# ── 4b. Declared inputs (2261-8gx5 (4)) ─────────────────────────────────────
# A fixture may DECLARE what it reads, in its first 40 lines:
#     # inputs: scripts/foo.sh scripts/lua/bar.lua openspec/litmus-tests/
#     -- inputs: …                         (a Lua fixture)
# The selector then trusts the declaration over the derived closure. The
# derived one is conservative on purpose: a dynamic path such as
# "$ROOT/scripts/${name}.sh" stops at the `$` and reads the WHOLE scripts/
# directory, which is why ~87 fixtures selected on any script change (measured
# 2026-11-23). --check-declared holds a declaration honest: every literal repo
# file the fixture names itself must be covered (exactly, or by a declared
# directory prefix ending in /).
: > "$WORK/decl"
while IFS=$'\t' read -r _did _drun _dpath _drest; do
    [ -f "$_dpath" ] || continue
    _dl="$(awk 'NR > 40 { exit } /^(#|--) inputs:/ { sub(/^(#|--) inputs:[[:space:]]*/, ""); print; exit }' "$_dpath" 2>/dev/null)"
    [ -n "$_dl" ] || continue
    for _di in $_dl; do printf '%s\t%s\n' "$_dpath" "$_di"; done
done < "$WORK/pop" >> "$WORK/decl"
sort -u -o "$WORK/decl" "$WORK/decl"
if [ "$MODE" = "--check-declared" ]; then
    awk -F'\t' -v W="$WORK" '
        FILENAME == W "/decl"  { D[$1] = D[$1] " " $2; next }
        FILENAME == W "/edges" {
            if (!($1 in D) || $2 ~ /\/$/ || $2 == "*" || $2 == $1) next
            n = split(D[$1], d, " "); ok = 0
            for (i = 1; i <= n; i++) if (d[i] != "" && ($2 == d[i] || (d[i] ~ /\/$/ && index($2, d[i]) == 1))) { ok = 1; break }
            if (!ok) { print "undeclared:" $1 ":" $2; bad++ }
            next
        }
        END { exit bad > 0 }' "$WORK/decl" "$WORK/edges" > "$WORK/undeclared"
    _ud=$?
    _nd="$(cut -f1 "$WORK/decl" | sort -u | grep -c .)"
    if [ "$_ud" -ne 0 ]; then
        cat "$WORK/undeclared"
        echo "violation:gate-changed-declared-inputs:$(wc -l < "$WORK/undeclared" | tr -d ' ') declaring=$_nd"
        echo "  why: a declared fixture is selected ONLY by its declaration, so a file it reads but does not declare would never select it" >&2
        echo "  remedy: add each undeclared path (or a directory prefix ending in /) to the fixture's inputs: line" >&2
        exit 1
    fi
    echo "ok:gate-changed-declared-inputs:$_nd declaring"
    exit 0
fi

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
FILENAME == W "/decl"    { DECL[$1] = DECL[$1] "\t" $2; next }
FILENAME == W "/pop"     {
    u = "fx:" $3 ($4 == "" ? "" : " " $4)
    if ($3 in DECL) {
        # 2261-8gx5: a declaring fixture reads itself, its declaration and its .step
        print u "\t" $3
        n = split(DECL[$3], parts, "\t")
        for (i = 1; i <= n; i++) if (parts[i] != "") print u "\t" parts[i]
    } else close_over($3, u)
    if ($7 != "") print u "\t" $7
    next
}
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
' "$WORK/edges" "$WORK/allsrc" "$WORK/decl" "$WORK/pop" "$WORK/crates" | sort -u > "$WORK/map"

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
# ORDER 2250-gwfy — AT INTAKE, A build.sh EDIT CONFINED TO WIRED FIXTURE
# BLOCKS IS NOT A GUARD HIT. Most build.sh edits add or change one
# `_step … if ! _run… ; _error … exit 1 ; fi ; _info …` block inside --check,
# and the replay (2249-tif9) found build.sh behind 11 of 22 HEAVY heads. The
# rule is deliberately STRICT: every added or removed line must be a block
# line (comment, blank, _step, `if ! _run`/`_run_lua_decider`, _error, _warn,
# exit 1, fi, _info) and lie inside the --check section; anything else (a
# variable, a trap, the step loop, a multi-line block with its own state)
# stays heavy:guard:build.sh. The fixtures named on the changed `_run` lines
# are then SELECTED (because=build.sh-block), alongside every fixture whose
# declared inputs name build.sh. Without --intake nothing here applies.
# The diff comes from git (`git diff -U0 <base> -- build.sh`), or, under
# --files, from TILLANDSIAS_GATE_CHANGED_BUILD_DIFF (the replay supplies it);
# with neither, build.sh stays a guard.
: > "$WORK/build-block-fx"
_build_block_only=0
if [ "$INTAKE" = 1 ] && grep -qx 'build.sh' "$WORK/changed"; then
    if [ -n "$FILES_FROM" ]; then
        _bd="${TILLANDSIAS_GATE_CHANGED_BUILD_DIFF:-}"
        [ -n "$_bd" ] && [ -f "$_bd" ] && cp "$_bd" "$WORK/build.diff" || : > "$WORK/build.diff"
    else
        git diff -U0 "$BASE" -- build.sh > "$WORK/build.diff" 2>/dev/null || : > "$WORK/build.diff"
    fi
    _chk_lo="$(grep -n '^if \[\[ "\$FLAG_CHECK" == true \]\]; then' build.sh | head -n 1 | cut -d: -f1)"
    _chk_hi="$(grep -n '^elif \[\[ "\$FLAG_TEST\$FLAG_CHECK' build.sh | head -n 1 | cut -d: -f1)"
    if [ -s "$WORK/build.diff" ] && [ -n "$_chk_lo" ] && [ -n "$_chk_hi" ]; then
        _bb="$(awk -v lo="$_chk_lo" -v hi="$_chk_hi" -v out="$WORK/build-block-fx" '
            /^@@/ { s = $0; sub(/^@@ -[0-9,]+ \+/, "", s); sub(/[, ].*/, "", s); n = s + 0; next }
            /^(\+\+\+|---)/ { next }
            /^[+-]/ {
                l = substr($0, 2)
                if (n < lo || n > hi) { bad = 1 }
                else if (l ~ /^[[:space:]]*(#.*)?$/ || l ~ /^[[:space:]]*_step "/ || l ~ /^[[:space:]]*_error "/ \
                    || l ~ /^[[:space:]]*_warn "/ || l ~ /^[[:space:]]*_info "/ || l ~ /^[[:space:]]*exit 1$/ || l ~ /^[[:space:]]*fi$/) { }
                else if (l ~ /^[[:space:]]*if ! _run_lua_decider "scripts\/lua\/[^"]+" 2>&1; then$/) {
                    f = l; sub(/.*_run_lua_decider "/, "", f); sub(/".*/, "", f); print f > out
                } else if (l ~ /^[[:space:]]*if ! _run bash "\$SCRIPT_DIR\/scripts\/[^"]+"( [^;]*)? 2>&1; then$/) {
                    f = l; sub(/.*_run bash "\$SCRIPT_DIR\//, "", f); sub(/".*/, "", f); print f > out
                } else { bad = 1 }
                if (substr($0, 1, 1) == "+") n++
                next
            }
            END { print (bad ? "machinery" : "block-only") }' "$WORK/build.diff")"
        [ "$_bb" = "block-only" ] && _build_block_only=1
    fi
fi
if [ -z "$_why_all" ]; then
    if [ "$_build_block_only" = 1 ]; then
        _g="$(grep -vx 'build.sh' "$WORK/changed" | grep -E "$_guard_re" | head -n 1)"
    else
        _g="$(grep -E "$_guard_re" "$WORK/changed" | head -n 1)"
    fi
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
if [ "$CHECKS" = 1 ]; then
    if [ -n "$_why_all" ]; then
        echo "select:checks-all reason=$_why_all"
        awk -F'\t' '{ print $1 ($4 == "" ? "" : " " $4) "\tall" }' "$WORK/pop" > "$WORK/fx-sel"
        _why_all=""
    fi
    : > "$WORK/fx-chk"; : > "$WORK/fx-chk-def"
    while IFS=$'\t' read -r _u _why; do
        _fp="${_u%% *}"
        case "${_fp##*/}" in check-*) ;; *) continue ;; esac
        if [ -n "$(awk 'NR > 40 { exit } /preflight: gate-only-decider/ { next } /^(#|--) preflight: gate-only/ { print; exit }' "$_fp" 2>/dev/null)" ]; then
            printf '%s\n' "$_u" >> "$WORK/fx-chk-def"
        else
            printf '%s\t%s\n' "$_u" "$_why" >> "$WORK/fx-chk"
        fi
    done < "$WORK/fx-sel"
    sort -u "$WORK/fx-chk" > "$WORK/fx-sel"; : > "$WORK/pkg-sel"; : > "$WORK/crate-hit"
    [ ! -s "$WORK/fx-chk-def" ] || echo "deferred:checks $(tr '\n' ' ' < "$WORK/fx-chk-def")"
fi
FX_N="$(wc -l < "$WORK/fx-sel" | tr -d ' ')"
PKG_N="$(wc -l < "$WORK/pkg-sel" | tr -d ' ')"
CRATE_TOTAL="$(wc -l < "$WORK/crates" | tr -d ' ')"

if [ -n "$_why_all" ]; then
    if [ "$INTAKE" = 1 ]; then
        # Intake never runs everything: the member goes to the bundle HEAVY.
        echo "heavy:$_why_all fixtures=$POP_N crates=$CRATE_TOTAL changed=$CHANGED_N"
        [ "$MODE" = "--run" ] && exit 10
        exit 0
    fi
    echo "select:all reason=$_why_all fixtures=$POP_N/$POP_N crates=$CRATE_TOTAL/$CRATE_TOTAL changed=$CHANGED_N"
    [ "$MODE" = "--run" ] && exit 10
    exit 0
fi

# 2250-gwfy: the fixtures a block-only build.sh edit wires are selected.
if [ "$_build_block_only" = 1 ] && [ -s "$WORK/build-block-fx" ]; then
    sort -u "$WORK/build-block-fx" | while IFS= read -r _bf; do
        # a REMOVED block names a fixture that may be gone: select only what
        # the population still runs, or the run loop would count it unrun.
        awk -F'\t' -v f="$_bf" '$3 == f && $4 == "" { found = 1 } END { exit !found }' "$WORK/pop" || continue
        grep -q "^$_bf	" "$WORK/fx-sel" 2>/dev/null || printf '%s\tbuild.sh-block\n' "$_bf"
    done >> "$WORK/fx-sel"
    sort -o "$WORK/fx-sel" "$WORK/fx-sel"
    FX_N="$(wc -l < "$WORK/fx-sel" | tr -d ' ')"
fi

# ORDER 2260-qw67: a guard build.sh declares `gate-context` (its preflight
# precondition table) answers about a RUNNING gate, not the tree, so a scoped run
# has no subject for it. It was run anyway, without the arguments its call site
# passes on a continuation line, and read could-not-run on every sample. Left out
# of the SELECTION, never of the population: its inputs must stay mapped, or a
# change to one would select everything. Named; the full gate still runs it.
awk -F'|' '/^_preflight_preconditions\(\)/ { t = 1; next } t && /^PRECONDS$/ { exit }
           t && $2 == "gate-context" { print $1 }' build.sh > "$WORK/gate-context"
if [ -s "$WORK/gate-context" ]; then
    : > "$WORK/fx-ctx"
    while IFS=$'\t' read -r _u _why; do
        _fp="${_u%% *}"
        if grep -qxF -- "${_fp##*/}" "$WORK/gate-context"; then
            echo "skip:gate-changed:gate-context:$_fp — build.sh declares it has no subject outside a running gate" >&2
        else
            printf '%s\t%s\n' "$_u" "$_why" >> "$WORK/fx-ctx"
        fi
    done < "$WORK/fx-sel"
    mv "$WORK/fx-ctx" "$WORK/fx-sel"
    FX_N="$(wc -l < "$WORK/fx-sel" | tr -d ' ')"
fi

# INTAKE: defer whole-tree readers and declared-slow fixtures to the bundle.
: > "$WORK/fx-deferred"
if [ "$INTAKE" = 1 ]; then
    : > "$WORK/fx-keep"
    while IFS=$'\t' read -r _u _why; do
        _fp="${_u%% *}"
        if [ "$_why" = "*" ]; then
            printf '%s\twhole-tree\n' "$_u" >> "$WORK/fx-deferred"
        # awk, not sed: `\(a\|b\)` alternation is GNU-only, and BSD sed matched
        # nothing, so on darwin no declared-slow fixture was ever deferred
        # (macbookair, #1402: 974's DEFER-SLOW arm red there and on trunk).
        elif [ -n "$(awk 'NR > 40 { exit } /preflight: gate-only-decider/ { next } /^(#|--) preflight: gate-only/ { print; exit }' "$_fp" 2>/dev/null)" ]; then
            printf '%s\tslow\n' "$_u" >> "$WORK/fx-deferred"
        else
            printf '%s\t%s\n' "$_u" "$_why" >> "$WORK/fx-keep"
        fi
    done < "$WORK/fx-sel"
    mv "$WORK/fx-keep" "$WORK/fx-sel"
    FX_N="$(wc -l < "$WORK/fx-sel" | tr -d ' ')"
fi
DEF_N="$(wc -l < "$WORK/fx-deferred" | tr -d ' ')"

if [ "$INTAKE" = 1 ]; then
    echo "select:intake fixtures=$FX_N/$POP_N deferred=$DEF_N crates=$PKG_N/$CRATE_TOTAL changed=$CHANGED_N base=${BASE:-files}"
else
    echo "select:scoped fixtures=$FX_N/$POP_N crates=$PKG_N/$CRATE_TOTAL changed=$CHANGED_N base=${BASE:-files}"
fi
while IFS=$'\t' read -r _u _why; do printf 'select:fixture:%s because=%s\n' "$_u" "$_why"; done < "$WORK/fx-sel"
while IFS= read -r _p; do printf 'select:crate:%s\n' "$_p"; done < "$WORK/pkg-sel"
if [ "$INTAKE" = 1 ]; then
    # ONE line naming everything the bundle gate owes this member.
    printf 'deferred: n=%s' "$DEF_N"
    while IFS=$'\t' read -r _u _k; do printf ' %s(%s)' "$_u" "$_k"; done < "$WORK/fx-deferred"
    printf '\n'
fi
[ "$MODE" = "--run" ] || exit 0

# ── 9. Run the selection ────────────────────────────────────────────────────
_plan=""
_plan="$(. scripts/plan-binary-probe.sh 2>/dev/null && resolve_plan_binary 2>/dev/null)" || _plan=""
case "$_plan" in ./*) _plan="$ROOT/${_plan#./}" ;; esac

# The repo's portable millisecond clock (BSD date prints a literal %3N).
. "$ROOT/scripts/timing-log.sh" 2>/dev/null || true
_now() { if command -v timing_now_ms >/dev/null 2>&1; then timing_now_ms; else echo $(( $(date +%s) * 1000 )); fi; }
_t0="$(_now)"; _fail=0; _ran=0

# ORDER 2256-mvmy — A PLAN-ONLY DIFF GOES TO THE PLAN LANE. Operator-approved
# 2026-11-20: plan changes get the plan-lane checks, never a build-check; at
# intake a plan-only follow-up took 247 s and 91 fixtures (2249-tif9 sample).
# The lane's own validators, each over this diff: `check --strict-fragments`
# and the fragment deciders the pre-push plan-only lane runs (its Lua port
# where one exists). One route:plan-lane line, then their verdicts.
if [ "$INTAKE" = 1 ] && ! grep -qvE '^plan/' "$WORK/changed"; then
    echo "route:plan-lane changed=$CHANGED_N (every path under plan/)"
    _ps="$(_now)"
    if [ -z "$_plan" ]; then
        echo "fail:gate-changed:plan-lane:no-plan-binary"; exit 1
    fi
    if ! _o="$("$_plan" check --strict-fragments 2>&1)"; then
        printf '%s\n' "$_o" | tail -n 20; echo "fail:gate-changed:plan-lane:check-strict-fragments"; _fail=$((_fail + 1))
    else
        echo "ok:gate-changed:plan-lane:check-strict-fragments"
    fi
    for _pd in check-added-fragments-parse check-scorable-obligation-added check-fragment-status-loss \
               check-fragment-ts-skew check-issue-citation-convention check-mo-full-attestations; do
        if [ -f "$ROOT/scripts/lua/$_pd.lua" ]; then
            _o="$(TILLANDSIAS_GATE_DIFF_BASE="$BASE" TILLANDSIAS_SCRIPT_RUNNER_BIN="$_plan" "$_plan" script run "$ROOT/scripts/lua/$_pd.lua" 2>&1)"; _rc=$?
        elif [ -f "$ROOT/scripts/$_pd.sh" ]; then
            _o="$(TILLANDSIAS_GATE_DIFF_BASE="$BASE" bash "$ROOT/scripts/$_pd.sh" 2>&1)"; _rc=$?
        else
            echo "skip:gate-changed:plan-lane:$_pd:absent"; continue
        fi
        if [ "$_rc" -ne 0 ]; then
            printf '%s\n' "$_o" | tail -n 20; echo "fail:gate-changed:plan-lane:$_pd rc=$_rc"; _fail=$((_fail + 1))
        else
            echo "ok:gate-changed:plan-lane:$_pd"
        fi
    done
    echo "phase:plan-lane ms=$(( $(_now) - _ps ))"
    if [ "$_fail" -gt 0 ]; then echo "fail:gate-changed:intake:plan-lane $_fail-failed ms=$(( $(_now) - _t0 ))"; exit 1; fi
    echo "ok:gate-changed:intake:plan-lane ms=$(( $(_now) - _t0 ))"
    exit 0
fi
if [ "$PKG_N" -gt 0 ]; then
    _pk=(); while IFS= read -r _p; do _pk+=(-p "$_p"); done < "$WORK/pkg-sel"
    _tr="$ROOT/target/test-transcript-changed.log"; mkdir -p "$ROOT/target"
    _s="$(_now)"
    _nx=""
    if [ "$INTAKE" = 1 ] && [ "${TILLANDSIAS_GATE_NEXTEST:-auto}" != 0 ]; then
        _nx="$(cargo nextest --version 2>/dev/null)" || _nx=""
        _nx="${_nx%%$'\n'*}"
    fi
    # 2256-mvmy: the build is its own phase, so the breakdown can say which
    # part of intake to cut (the test runs below then start from warm binaries).
    if [ "$INTAKE" = 1 ]; then
        _bs="$(_now)"
        cargo test --no-run "${_pk[@]}" --manifest-path "$ROOT/Cargo.toml" > "$WORK/build.log" 2>&1 || true
        echo "phase:cargo-build ms=$(( $(_now) - _bs ))"
        _s="$(_now)"
    fi
    if [ -n "$_nx" ]; then
        # The crates that CHANGED, each with its reverse-dep closure, as one
        # filterset: rdeps(x) is x and everything that depends on it.
        _fs=""
        while IFS= read -r _d; do
            _n="$(awk -F'\t' -v d="$_d" '$1 == d { print $2 }' "$WORK/crates")"
            [ -n "$_n" ] && _fs="${_fs:+$_fs | }rdeps($_n)"
        done < "$WORK/crate-hit"
        echo "runner:nextest:${_nx#cargo-nextest } filter=$_fs"
        # Under target/, never $WORK in /tmp: the converter reads only inside the
        # repository, and a refused read made every green run here read red (2285-jvg6).
        _nx_log="$ROOT/target/nextest-changed.log"
        cargo nextest run --workspace --no-fail-fast -E "$_fs" --manifest-path "$ROOT/Cargo.toml" > "$_nx_log" 2>&1
        _crc=$?
        # The baseline check reads cargo test's transcript shape.
        _conv_bad=1
        _conv="no plan binary with \`script run\` resolves"
        if [ -n "$_plan" ] && ( cd "$ROOT" && "$_plan" script run --helper scripts/lua/nextest-to-libtest.lua -- "$_nx_log" ) > "$_tr" 2> "$WORK/conv.err"; then
            _conv_bad=0
        elif [ -n "$_plan" ]; then
            _conv="$(cat "$WORK/conv.err" "$_tr")"; _conv="${_conv:-the converter failed and printed nothing}"
        fi
        echo "phase:nextest ms=$(( $(_now) - _s ))"
        # 2256-mvmy: nextest runs no doctests, and the gate adds them after the
        # converted log (build.sh, 2243-urcy); those `test result:` lines are
        # what check-test-baseline counts. Without them a green nextest run
        # read as no-test-results. Only crates with a lib target have any.
        _ds="$(_now)"; _dk=()
        while IFS= read -r _d; do
            [ -f "$ROOT/$_d/src/lib.rs" ] || continue
            _n="$(awk -F'\t' -v d="$_d" '$1 == d { print $2 }' "$WORK/crates")"
            [ -n "$_n" ] && _dk+=(-p "$_n")
        done < "$WORK/crate-sel"
        if [ "${#_dk[@]}" -gt 0 ]; then
            cargo test --doc --no-fail-fast "${_dk[@]}" --manifest-path "$ROOT/Cargo.toml" >> "$_tr" 2>&1 || _crc=$?
        fi
        echo "phase:doctests ms=$(( $(_now) - _ds )) crates=$(( ${#_dk[@]} / 2 ))"
    else
        if [ "$INTAKE" = 1 ]; then
            if [ "${TILLANDSIAS_GATE_NEXTEST:-auto}" = 0 ]; then echo "runner:cargo-test:forced-by-TILLANDSIAS_GATE_NEXTEST=0"
            else echo "runner:cargo-test:nextest-absent"; fi
        fi
        cargo test --no-fail-fast "${_pk[@]}" --manifest-path "$ROOT/Cargo.toml" > "$_tr" 2>&1
        _crc=$?
        [ "$INTAKE" = 1 ] && echo "phase:cargo-test ms=$(( $(_now) - _s ))"
    fi
    if [ "${_conv_bad:-0}" = 1 ]; then
        echo "fail:gate-changed:nextest-transcript log=$_nx_log rc=$_crc — the result log could not be converted, so the tests were not judged"
        printf '%s\n' "$_conv" | sed 's/^/  /'
        _fail=$((_fail + 1))
    elif ! _v="$(bash scripts/check-test-baseline.sh --from "$_tr")"; then
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

# BEGIN-FX-POOL
# ORDER 1931-steb — THE SELECTED FIXTURES RUN IN PARALLEL, at most
# GATE_CHANGED_JOBS at once (default: nproc; 1 is the old serial loop). Each
# writes its own log, rc and ms under $WORK/fx.<n>, and the results are printed
# afterwards in selection order, so the output reads exactly as the serial
# loop's did. A fixture whose header declares `# preflight: serial — <reason>`
# (the door's declaration, build.sh) runs ALONE: the pool drains first.
# bash 3.2 has no `wait -n`, so a full pool is polled at 0.1 s.
# Pinned by scripts/lua/test-gate-changed-parallel-fixtures.lua.
_jobs="${GATE_CHANGED_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)}"
case "$_jobs" in ''|*[!0-9]*|0) _jobs=1 ;; esac
_fx_running() { jobs -pr | wc -l | tr -d ' '; }
_fx_wait_below() { while [ "$(_fx_running)" -ge "$1" ]; do sleep 0.1; done; }
_fx_one() { # _fx_one <n> <runner> <path> <args> <adv>
    local _o="$WORK/fx.$1" _s _rc
    _s="$(_now)"
    if [ "$2" = lua ]; then
        # shellcheck disable=SC2086
        TILLANDSIAS_SCRIPT_RUNNER_BIN="$_plan" "$_plan" script run "$ROOT/$3" -- $4 > "$_o.out" 2>&1 </dev/null
    else
        # shellcheck disable=SC2086
        bash "$ROOT/$3" $4 > "$_o.out" 2>&1 </dev/null
    fi
    _rc=$?
    case "$5" in skip=*) [ "$_rc" = "${5#skip=}" ] && _rc=0 ;; 1) _rc=0 ;; esac
    echo "$(( $(_now) - _s ))" > "$_o.ms"; echo "$_rc" > "$_o.rc"
}
: > "$WORK/fx.order"; : > "$WORK/fx.serial"
# 2256-mvmy: the loop reads a FILE, never a process substitution. A serial
# row calls `wait`, and on the real tree (population > the 64 KB pipe buffer)
# that wait sat on the `tr` feeding the loop while `tr` blocked writing to the
# pipe only the waiting loop drains: measured on lenovinha, the intake run in
# do_wait for 46 min with tr in anon_pipe_write and no fixture started.
tr '\t' '\037' < "$WORK/pop" > "$WORK/pop.us"
_fxs="$(_now)"
while IFS=$'\037' read -r _id _runner _path _args _adv _desc _rest; do
    grep -qxF -- "$_id${_args:+ $_args}" "$WORK/fx-sel.ids" || continue
    _ran=$((_ran + 1))
    printf '%s\t%s\n' "$_ran" "$_path" >> "$WORK/fx.order"
    if [ "$_runner" = lua ] && [ -z "$_plan" ]; then
        echo "could-not-run:gate-changed:no-plan-binary:$_path" > "$WORK/fx.$_ran.out"
        echo 127 > "$WORK/fx.$_ran.rc"; echo 0 > "$WORK/fx.$_ran.ms"; continue
    fi
    # 2256-mvmy: at intake, run serially everything --check never runs beside
    # another fixture: an inline build.sh block (serial by construction; such a
    # row names no .step file) and a .step declaring STEP_SERIAL. Only an
    # undeclared .step is known pool-safe — it is what the gate-steps pool
    # already runs concurrently. Measured on 10 landed-green merges: the pool
    # ran these side by side and every scoped run reported 7-13 false reds.
    # (Without --intake the loop keeps its header-only rule; legacy --changed
    # has the same defect and is a developer loop, so it is left as it was.)
    _ser=0
    [ -n "$(awk 'NR > 40 { exit } /^(#|--) preflight: serial/ { print; exit }' "$ROOT/$_path" 2>/dev/null)" ] && _ser=1
    if [ "$INTAKE" = 1 ]; then
        _sf="${_rest%%$'\037'*}"
        if [ -z "$_sf" ]; then _ser=1
        elif grep -q '^STEP_SERIAL=' "$ROOT/$_sf" 2>/dev/null; then _ser=1; fi
    fi
    if [ "$_ser" = 1 ]; then
        printf '%s\n' "$_ran" >> "$WORK/fx.serial"
        wait; _fx_one "$_ran" "$_runner" "$_path" "$_args" "$_adv"
    else
        _fx_wait_below "$_jobs"
        _fx_one "$_ran" "$_runner" "$_path" "$_args" "$_adv" &
    fi
done < "$WORK/pop.us"
wait
if [ "$INTAKE" = 1 ]; then
    _sms=0; _sn=0
    while IFS= read -r _n; do _sms=$(( _sms + $(cat "$WORK/fx.$_n.ms" 2>/dev/null || echo 0) )); _sn=$((_sn + 1)); done < "$WORK/fx.serial"
    _fxw=$(( $(_now) - _fxs ))
    echo "phase:serial-fixtures ms=$_sms n=$_sn"
    echo "phase:pool ms=$(( _fxw > _sms ? _fxw - _sms : 0 )) n=$(( _ran - _sn ))"
fi
while IFS=$'\t' read -r _n _path; do
    _rc="$(cat "$WORK/fx.$_n.rc" 2>/dev/null || echo 125)"; _ms="$(cat "$WORK/fx.$_n.ms" 2>/dev/null || echo 0)"
    if [ "$_rc" -ne 0 ]; then
        tail -n 20 "$WORK/fx.$_n.out"; echo "fail:gate-changed:fixture:$_path rc=$_rc ms=$_ms"; _fail=$((_fail + 1))
    else
        echo "ok:gate-changed:fixture:$_path ms=$_ms"
    fi
done < "$WORK/fx.order"
# END-FX-POOL

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
if [ "$INTAKE" = 1 ]; then
    echo "ok:gate-changed:intake fixtures=$_ran deferred=$DEF_N crates=$PKG_N ms=$_total"
    exit 0
fi
echo "ok:gate-changed fixtures=$_ran crates=$PKG_N ms=$_total"
exit 0
