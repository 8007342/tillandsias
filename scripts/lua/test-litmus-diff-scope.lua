-- @trace spec:litmus-framework, order:765-mza8, order:634-39ik, order:2110-ghw2, order:2387-lrg2
-- @env PATH HOME
--
-- test-litmus-diff-scope.lua — fixtures for order 765-mza8. Ported from test-litmus-diff-scope.sh
-- (2387-lrg2); same twenty checks in six scenarios, in its order.
--
-- The selector REMOVES coverage, so the property is not "it skips tests" — any broken
-- implementation does that. It is: EVERY uncertainty runs the full suite.
--
--   A  accessor parity: yq path and awk fallback agree on every annotated file (vacuous without
--      yq); at least one test carries inputs:
--   B  glob semantics: crates/** crosses /; unrelated globs miss; empty never intersects;
--      an exact subtree matches
--   C  fail-closed: not a repo / unresolvable base / no changes / no anchor / anchor older
--      than 24h / corrupt anchor each leave DIFF_SCOPE_ACTIVE=0 and say why
--   D  happy path: ACTIVE=1, uncommitted AND untracked paths captured, sentinel written
--   E  gate-stamp veto: build.sh's _write_gate_stamp refuses and consumes the sentinel
--   F  dead-glob guard negative control (634-39ik): check-litmus-dead-inputs.lua passes a
--      live glob and refuses a dead one by name
--
-- C, D and E drive the REAL functions, awk-extracted from run-litmus-test.sh and build.sh,
-- through one posix_shell harness (proc.run denies `bash -c`): the harness evals them and
-- prints what it saw; every assertion is made here.
--
-- PORT NOTE. Scratch lives under the checkout, so the not-a-repo arm sets
-- GIT_CEILING_DIRECTORIES to its parent: without it git finds the checkout above and the arm
-- tests nothing. The F guard runs with PROJECT_ROOT and TILLANDSIAS_* unset (the .sh's
-- `env -u PROJECT_ROOT -u TILLANDSIAS_REPO_ROOT`). The .sh's TILLANDSIAS_TIMING_LOG export
-- guarded a runner this fixture never spawns, so it is not carried.
--
-- GRAMMAR ok:litmus-diff-scope:<n> arms | violation:litmus-diff-scope:<n>-failed
--       | skip:litmus-diff-scope:no-validator

local fixture = require "common.fixture"
local T = fixture.new("litmus-diff-scope")
local ROOT = fixture.repo_root()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:skip("no-validator") end
local SH = fixture.posix_shell()
local UNSET = { "TILLANDSIAS_*", "PROJECT_ROOT" }
local W = T:scratch()

fs.write(W.rel .. "/harness.sh", [==[
RUNNER="$1"; BUILD="$2"; mode="$3"; shift 3
extract_fn() { awk -v fn="$1" '$0 ~ "^" fn "\\(\\) \\{" { c=1 } c { print } c && /^\}/ { exit }' "$2"; }
for fn in get_test_inputs litmus_inputs_intersect_diff litmus_resolve_diff_scope litmus_record_full_anchor litmus_mark_scoped_run; do
    body="$(extract_fn "$fn" "$RUNNER")"
    case "$body" in "$fn() {"*) ;; *) echo "STALE:$fn"; exit 3 ;; esac
    eval "$body"
done
LOG_LINES=""
log_warn() { LOG_LINES="${LOG_LINES}WARN:$*
"; }
log_info() { LOG_LINES="${LOG_LINES}INFO:$*
"; }
DIFF_SCOPE_ACTIVE=0; DIFF_SCOPE_BASE_SHA=""; DIFF_SCOPE_CHANGED=""
case "$mode" in
parity)
    nonyq="$1"; shift; mkdir -p "$nonyq"; sp=""; sh_=0
    IFS=: read -ra parts <<<"$PATH"
    for d in "${parts[@]}"; do
        if [ -x "$d/yq" ]; then
            for e in "$d"/*; do [ "${e##*/}" = yq ] && continue; [ -e "$nonyq/${e##*/}" ] || ln -s "$e" "$nonyq/${e##*/}" 2>/dev/null; done
            [ "$sh_" = 0 ] && { sp="${sp:+$sp:}$nonyq"; sh_=1; }
            continue
        fi
        sp="${sp:+$sp:}$d"
    done
    ann=0; bad=0; files=0; fnbody="$(extract_fn get_test_inputs "$RUNNER")"
    for f in "$@"; do
        files=$((files + 1))
        a="$(get_test_inputs "$f")"
        b="$(PATH="$sp" eval "$fnbody"; PATH="$sp" get_test_inputs "$f")"
        [ -n "$a" ] && ann=$((ann + 1))
        [ "$a" = "$b" ] || { bad=$((bad + 1)); echo "MISMATCH:${f##*/}"; }
    done
    if command -v yq >/dev/null 2>&1; then echo "YQ=1"; else echo "YQ=0"; fi
    echo "FILES=$files"; echo "ANNOTATED=$ann"; echo "MISMATCHES=$bad" ;;
intersect)
    if litmus_inputs_intersect_diff "$1" "$2"; then echo HIT; else echo MISS; fi ;;
resolve)
    PROJECT_ROOT="$1"; litmus_resolve_diff_scope "$2"
    echo "ACTIVE=$DIFF_SCOPE_ACTIVE"; printf '%s' "$LOG_LINES"
    printf '%s\n' "$DIFF_SCOPE_CHANGED" | sed 's/^/CH:/' ;;
mark)
    PROJECT_ROOT="$1"; DIFF_SCOPE_BASE_SHA="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"; litmus_mark_scoped_run 7 ;;
stamp)
    stamp_fn="$(extract_fn _write_gate_stamp "$BUILD")"
    [ -n "$stamp_fn" ] || { echo "STALE:_write_gate_stamp"; exit 3; }
    cd "$1" || exit 1
    _warn() { printf 'WARN:%s\n' "$*"; }
    eval "$stamp_fn"; _write_gate_stamp 2>&1 ;;
esac
]==])

local function H(mode, args, extra_env)
    local a = { SH, W.abs .. "/harness.sh", ROOT .. "/scripts/run-litmus-test.sh", ROOT .. "/build.sh", mode }
    for _, x in ipairs(args or {}) do a[#a + 1] = x end
    a.cwd, a.env_unset, a.env, a.stdin, a.timeout_ms = ROOT, UNSET, extra_env, "", 120000
    local r = T:run(a)
    return (r.stdout or "") .. (r.stderr or ""), r.code
end
local function line_is(s, want) for _, l in ipairs(text.lines(s)) do if l == want then return true end end return false end
local function field(s, k) for _, l in ipairs(text.lines(s)) do local v = l:match("^" .. k .. "=(.*)$"); if v then return v end end end
local function oneline(s) return (s:gsub("\n", "|")) end

-- A
local yamls = {}
for _, e in ipairs(fs.list("openspec/litmus-tests") or {}) do
    if e:match("^litmus%-.*%.yaml$") then yamls[#yamls + 1] = ROOT .. "/openspec/litmus-tests/" .. e end
end
table.sort(yamls)
local pargs = { W.abs .. "/nonyq-bin" }
for _, f in ipairs(yamls) do pargs[#pargs + 1] = f end
local po = H("parity", pargs)
local yq = field(po, "YQ")
T:arm("A1 yq and awk fallback agree on every file (vacuous when yq is absent: yq=" .. tostring(yq) .. ")",
    field(po, "MISMATCHES") == "0" and tonumber(field(po, "FILES") or "0") == #yamls and #yamls > 0, oneline(po))
T:arm("A2 at least one test carries inputs: annotations", tonumber(field(po, "ANNOTATED") or "0") > 0, oneline(po))

-- B
local CH = "crates/tillandsias-plan/src/main.rs\nplan/index.d/x.yaml"
T:arm("B1 crates/** matches a nested path", text.trim(H("intersect", { "crates/**", CH })) == "HIT", "")
T:arm("B2 unrelated globs do not intersect", text.trim(H("intersect", { "images/git/**\nscripts/build-image.sh", CH })) == "MISS", "")
T:arm("B3 an empty annotation never intersects (unannotated => always runs)", text.trim(H("intersect", { "", CH })) == "MISS", "")
T:arm("B4 an exact-subtree glob matches", text.trim(H("intersect", { "plan/index.d/**", CH })) == "HIT", "")

-- C
local function new_repo(tag, edit)
    local d = T:git_repo(tag)
    if edit then fs.write(d.rel .. "/README", "fixture\nedit\n") end
    return d
end
local function gitdir(d) return text.trim(T:must{ "git", "-C", d.abs, "rev-parse", "--absolute-git-dir" }.stdout or "") end
local function now_s() return tonumber(text.trim(T:must{ "date", "-u", "+%s" }.stdout or "")) end
local function anchor(d, body)
    local gd = gitdir(d)
    -- the anchor lives in the scratch repo's git dir, reached by its repo-relative path
    fs.write(d.rel .. "/.git/tillandsias-litmus-full-anchor", body .. "\n")
    return gd
end
local function refuses(label, o, want)
    T:arm(label, field(o, "ACTIVE") == "0" and text.contains(o, want), oneline(o))
end
local NR = T:scratch("norepo")
fs.mkdir(NR.rel .. "/not-a-repo")
refuses("C1 not a git repository => FULL",
    H("resolve", { NR.abs .. "/not-a-repo", "HEAD" }, { GIT_CEILING_DIRECTORIES = NR.abs }), "not a git repository")
refuses("C2 unresolvable base ref => FULL", H("resolve", { new_repo("c2").abs, "no-such-ref-xyz" }), "does not resolve")
refuses("C3 clean tree (no changes) => FULL", H("resolve", { new_repo("c3").abs, "HEAD" }), "no changes against")
refuses("C4 no full-run anchor => FULL", H("resolve", { new_repo("c4", true).abs, "HEAD" }), "no full-run anchor")
local c5 = new_repo("c5", true); anchor(c5, tostring(now_s() - 90000))
refuses("C5 anchor older than 24h => FULL (ratchet)", H("resolve", { c5.abs, "HEAD" }), "older than 24h")
local c6 = new_repo("c6", true); anchor(c6, "not-a-timestamp")
refuses("C6 corrupt anchor => FULL (treated as epoch 0)", H("resolve", { c6.abs, "HEAD" }), "older than 24h")

-- D
local d = new_repo("d", true)
fs.mkdir(d.rel .. "/crates/foo/src")
fs.write(d.rel .. "/crates/foo/src/main.rs", "fn main(){}\n")
local gd = anchor(d, tostring(now_s()))
local o = H("resolve", { d.abs, "HEAD" })
T:arm("D1 valid base + changes + fresh anchor => ACTIVE", field(o, "ACTIVE") == "1", oneline(o))
T:arm("D2 an uncommitted tracked edit is in the change set", line_is(o, "CH:README"), oneline(o))
T:arm("D3 an untracked new file is in the change set", line_is(o, "CH:crates/foo/src/main.rs"), oneline(o))
H("mark", { d.abs })
local SENT = d.rel .. "/.git/tillandsias-litmus-diff-scoped"
T:arm("D4 a scoped run leaves the sentinel build.sh vetoes on",
    fs.exists(SENT) and text.contains(fs.read(SENT) or "", "skips=7"), "gitdir=" .. gd)

-- E
o = H("stamp", { d.abs })
T:arm("E1 the scoped sentinel vetoes the gate stamp", text.contains(o, "NOT writing a gate stamp"), oneline(o))
T:arm("E2 the sentinel is consumed, so a later full run can stamp again", not fs.exists(SENT), "")

-- F
local ctl = T:scratch("deadglob")
for _, p in ipairs({ "openspec/litmus-tests", "scripts/lua", "crates/real/src" }) do fs.mkdir(ctl.rel .. "/" .. p) end
fs.write(ctl.rel .. "/scripts/lua/check-litmus-dead-inputs.lua", fs.read("scripts/lua/check-litmus-dead-inputs.lua"))
fs.write(ctl.rel .. "/crates/real/src/main.rs", "fn main(){}\n")
T:must{ "git", "-C", ctl.abs, "init", "-q" }
T:must{ "git", "-C", ctl.abs, "config", "user.email", "t@example.com" }
T:must{ "git", "-C", ctl.abs, "config", "user.name", "t" }
local NS = "litmus"
local function yaml(name, glob)
    return "name: " .. NS .. ":" .. name .. "\nsize: instant\ninputs:\n  - " .. glob .. "\nphase: pre-build\n"
end
local function commit(msg)
    T:must{ "git", "-C", ctl.abs, "add", "-A" }
    T:must{ "git", "-C", ctl.abs, "-c", "commit.gpgsign=false", "commit", "-qm", msg }
end
local function dead_inputs()
    local r = T:run{ PLAN, "script", "run", "scripts/lua/check-litmus-dead-inputs.lua",
        cwd = ctl.abs, env_unset = UNSET, stdin = "", timeout_ms = 60000 }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
fs.write(ctl.rel .. "/openspec/litmus-tests/litmus-live.yaml", yaml("live", "crates/**")); commit("seed")
local rc, fo = dead_inputs()
T:arm("F1 the dead-glob guard passes when every glob resolves", rc == 0, "rc=" .. tostring(rc) .. " " .. oneline(fo))
fs.write(ctl.rel .. "/openspec/litmus-tests/litmus-dead.yaml", yaml("dead", "crate/**")); commit("dead")
rc, fo = dead_inputs()
T:arm("F2 the guard refuses a dead glob 'crate/**' and names it",
    rc ~= 0 and text.contains(fo, "violation:litmus-dead-inputs:1") and text.contains(fo, "crate/**"),
    "rc=" .. tostring(rc) .. " " .. oneline(fo))

T:finish()
