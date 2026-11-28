-- @trace order:1916-tsel, order:1916-gbct, order:2344-zk8r, spec:ci-release
-- @env GATE_CHANGED_FX_INNER
--
-- test-gate-changed-selects-by-input.lua — `./build.sh --changed [base]`
-- (scripts/gate-changed.sh) runs ONLY what intersects the diff, and falls back to
-- EVERYTHING when it cannot tell. A stub tree is changed one path at a time.
-- Ported from the .sh (2344-zk8r).
--
--   1 touching fixture A's input selects A and not B
--   2 touching B's input does not select A
--   3 a crate change selects that crate and its reverse dependents only
--   4 a path nothing declares selects everything (fail-safe)
--   5 a guard file (build.sh) selects everything
--   6 a .step file selects the fixture it wires, not everything
--   7 the real tree's population is not empty (a broken extractor is not green)
--   8 build.sh accepts --changed and dispatches to gate-changed.sh
--   9 --run RUNS what --list selects (an empty tab field once shifted the row and
--     nothing ran), and a red selected fixture fails the run
--  10 (2260-qw67) run with TILLANDSIAS_GATE_CHANGED_ROOT naming another tree, still green
--  11 (2260-qw67) a guard declared gate-context is not run, and is named; its neighbours are
--
-- Verdict: ok:gate-changed-selects-by-input:<n> | violation:gate-changed-selects-by-input:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-changed-selects-by-input")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local SUBJECT = ROOT .. "/scripts/gate-changed.sh"
if not fs.exists("scripts/gate-changed.sh") then T:refuse("subject-missing") end

local W = T:scratch()
local tree = W.rel .. "/tree"
for _, d in ipairs{ "scripts/gate-steps.d", "data", "notes", "crates/base/src", "crates/leaf/src", "crates/other/src" } do fs.mkdir(tree .. "/" .. d) end
local function put(p, s) fs.write(tree .. "/" .. p, s) end
put("scripts/gate-changed.sh", fs.read("scripts/gate-changed.sh"))
local BUILD = [==[
#!/usr/bin/env bash
if [[ "$FLAG_CHECK" == true ]]; then
    _step "Checking A..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-a.sh" 2>&1; then exit 1; fi
    _step "Checking B..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-b.sh" 2>&1; then exit 1; fi
    _step "Checking D..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-d.sh" 2>&1; then exit 1; fi
    _step "Checking E..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-e.sh" 2>&1; then exit 1; fi
elif [[ "$FLAG_TEST$FLAG_CHECK" == "falsefalse" ]]; then
    :
fi
]==]
put("build.sh", BUILD)
for f, word in pairs{ a = "alpha", b = "beta", c = "gamma" } do
    put("scripts/test-" .. f .. ".sh", '#!/usr/bin/env bash\nROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"\ngrep -q ' .. word .. ' "$ROOT/data/' .. f .. '.txt"\n')
    put("data/" .. f .. ".txt", word .. "\n")
end
put("scripts/gate-steps.d/010-c.step", 'STEP_DESC="Checking C"\nSTEP_SCRIPT="scripts/test-c.sh"\nSTEP_ERROR="c failed"\nSTEP_OK="c ok"\n')
put("NOTES.unmapped", "notes\n")
-- 2422-4yak: test-d names a scratch path ending in a top-level dir (it reads a copy, not
-- notes/); test-e reads the REAL notes/ through its root ("$ROOT"/notes, cut as "/notes").
put("notes/n.txt", "n\n")
put("scripts/test-d.sh", '#!/usr/bin/env bash\ntmp="$(mktemp -d)"; mkdir -p "$tmp/foo/bar/notes"\nls foo/bar/notes >/dev/null 2>&1; rm -rf "$tmp"\n')
put("scripts/test-e.sh", '#!/usr/bin/env bash\nROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"\nls "$ROOT"/notes >/dev/null\n')
put("Cargo.toml", '[workspace]\nmembers = [\n    "crates/base",\n    "crates/leaf",\n    "crates/other",\n]\n')
for _, c in ipairs{ "base", "leaf", "other" } do
    put("crates/" .. c .. "/Cargo.toml", '[package]\nname = "stub-' .. c .. '"\n' .. (c == "leaf" and '\n[dependencies]\nstub-base = { path = "../base" }\n' or ""))
    put("crates/" .. c .. "/src/lib.rs", "pub fn f() {}\n")
end
-- 2422-4yak: an API URL whose path ends in a top-level directory name (the Cloudflare
-- ".../workers/scripts" endpoints made tillandsias-headless read all of scripts/).
put("crates/other/src/lib.rs", 'pub const U: &str = "https://api.example.com/client/v4/accounts/{account}/workers/scripts";\npub fn f() {}\n')
T:must{ "git", "-C", W.abs .. "/tree", "init", "-q" }

-- Every child judges THIS fixture's tree, never one the caller's environment names.
local function gate(script, mode, ...)
    fs.write(W.rel .. "/changed", table.concat({ ... }, "\n") .. "\n")
    local r = T:run{ SH, script, mode, "--files", W.abs .. "/changed", cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 300000 }
    return (r.stdout or "") .. (r.stderr or ""), r.code
end
local STUB = W.abs .. "/tree/scripts/gate-changed.sh"
local function sel(...) return gate(STUB, "--list", ...) end
local function has(o, s) return o:find(s, 1, true) ~= nil end

local o = sel("data/a.txt")
T:arm("1 a fixture's input selects it and not its neighbour", has(o, "select:fixture:scripts/test-a.sh") and not has(o, "scripts/test-b.sh") and not has(o, "select:all"), o)
o = sel("data/b.txt")
T:arm("2 an unrelated input does not select test-a", has(o, "select:fixture:scripts/test-b.sh") and not has(o, "scripts/test-a.sh"), o)
o = sel("crates/base/src/lib.rs")
local o2 = sel("crates/other/src/lib.rs")
T:arm("3 a crate selects itself and its reverse dependents only", has(o, "select:crate:stub-base") and has(o, "select:crate:stub-leaf") and not has(o, "stub-other")
    and has(o2, "select:crate:stub-other") and not has(o2, "stub-base") and not has(o2, "stub-leaf"), "base-> " .. o .. " other-> " .. o2)
o = sel("NOTES.unmapped")
T:arm("4 an unmapped path selects everything", has(o, "select:all reason=unmapped:NOTES.unmapped"), o)
o = sel("build.sh")
T:arm("5 a guard file selects everything", has(o, "select:all reason=guard:build.sh"), o)
o = sel("scripts/gate-steps.d/010-c.step")
T:arm("6 a .step file selects exactly the fixture it wires", has(o, "select:fixture:scripts/test-c.sh") and not has(o, "select:all") and not has(o, "test-a.sh"), o)

o = gate(SUBJECT, "--list", "no/such/path.unmapped")
local n = tonumber(o:match("fixtures=%d*/(%d+)")) or 0
T:arm("7 the real tree's population is the size of the gate, and fails safe", has(o, "select:all") and n >= 300, "population=" .. n .. " " .. o:sub(1, 300))

local build = "\n" .. fs.read("build.sh")
T:arm("8 build.sh dispatches --changed to gate-changed.sh --run", build:find("\n%s+%-%-changed%)") and has(build, 'scripts/gate-changed.sh" --run'), "no --changed flag, or it does not dispatch")

local rc, rc2
o, rc = gate(STUB, "--run", "data/a.txt")
put("data/a.txt", "delta\n")
o2, rc2 = gate(STUB, "--run", "data/a.txt")
T:arm("9 --run executes exactly the selection, and a red fixture fails it", rc == 0 and has(o, "ok:gate-changed:fixture:scripts/test-a.sh")
    and has(o, "ok:gate-changed fixtures=1 ") and rc2 == 1 and has(o2, "fail:gate-changed:fixture:scripts/test-a.sh"),
    "rc=" .. tostring(rc) .. " [" .. o .. "] red rc=" .. tostring(rc2) .. " [" .. o2 .. "]")

-- One level of recursion, stopped by the marker.
if (env.get("GATE_CHANGED_FX_INNER") or "") == "" then
    fs.mkdir(W.rel .. "/other")
    local r = T:run{ PLAN, "script", "run", "scripts/lua/test-gate-changed-selects-by-input.lua", cwd = ROOT, timeout_ms = 600000,
        env = { GATE_CHANGED_FX_INNER = "1", TILLANDSIAS_GATE_CHANGED_ROOT = W.abs .. "/other" } }
    -- any arm count: the inner run fails on its own if one of its arms does (a fixed count broke on every new arm)
    T:arm("10 an inherited TILLANDSIAS_GATE_CHANGED_ROOT is not followed", r.code == 0 and (r.stdout or ""):find("ok:gate%-changed%-selects%-by%-input:%d+") ~= nil,
        "rc=" .. tostring(r.code) .. " " .. ((r.stdout or "") .. (r.stderr or "")):gsub("\n", " | "))
end

put("build.sh", BUILD .. "_preflight_preconditions() {\n    cat <<'PRECONDS'\ntest-a.sh|gate-context|answers about a running gate\n"
    .. "test-b.sh|policy-binary|some other precondition\nPRECONDS\n}\n")
o = sel("data/a.txt", "data/b.txt")
T:arm("11 a gate-context guard is not run and is named; its neighbour runs", not has(o, "select:fixture:scripts/test-a.sh")
    and has(o, "select:fixture:scripts/test-b.sh") and has(o, "skip:gate-changed:gate-context:scripts/test-a.sh"), o)
put("build.sh", BUILD)
-- 2422-4yak: a token that reaches a bare top-level directory only by stripping counts
-- only when what it stripped is a repo-root name.
o = sel("scripts/test-a.sh")
T:arm("12 a URL ending /workers/scripts does not make a crate read scripts/", has(o, "select:fixture:scripts/test-a.sh") and not has(o, "stub-other"), o)
o = sel("notes/n.txt")
T:arm("13 a scratch path foo/bar/notes does not select its fixture for a notes/ change", not has(o, "scripts/test-d.sh"), o)
T:arm("14 CONTROL a \"$ROOT\"/notes read still selects its fixture", has(o, "select:fixture:scripts/test-e.sh") and not has(o, "select:all"), o)
T:finish({ ok = function(k) return "ok:gate-changed-selects-by-input:" .. k end })
