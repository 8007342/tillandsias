-- @trace order:660-ryhn, spec:ci-release, order:2386-lrg1
-- @env TMPDIR
--
-- test-litmus-bindings.lua — hermetic fixture for scripts/lua/check-litmus-bindings.lua, run
-- on `tillandsias-plan script run`. Ported from test-litmus-bindings.sh (2386-lrg1); same ten
-- cases. The negative controls are the point: the failure mode this gate closes is SILENCE.
--
-- The corpora live OUTSIDE the checkout (a scratch root declared under $TMPDIR), as the .sh's
-- mktemp did: under target/plan-scratch the checker's `git -C <root>` would find THIS repo and
-- its base ref, and case 10 (no base ref) would stop being the case it names. The fabricated
-- test names are COMPOSED at runtime (LP) so check-litmus-pin-claims.sh reads no claim here.
-- No child runs build.sh (the .sh names it only in a comment).
--
--   1  the ok verdict carries all the counts, on a bounded corpus
--   2  a clean tree: files=3 bound=1 retired=1 grandfathered=1 spec_ids=1 resolved=1
--   3  NEGATIVE a new unbound file exits 1, named
--   4  NEGATIVE a dangling binding exits 1, named
--   5  phase: retired is the sanctioned unbound state
--   6  NEGATIVE a spec_id resolving to nothing is refused by name (1356-vv5m)
--   7  NEGATIVE an empty spec directory is not a resolved spec
--   8  NEGATIVE zero parsed spec_ids is refused, not reported clean
--   9  a declared unresolved spec_id is exempt and counted separately
--  10  no base ref names the skipped diff-scoped checks on stderr (1570-qutp)
--
-- GRAMMAR ok:litmus-bindings-fixture:<n> arms | violation:litmus-bindings-fixture:<n>-failed
--       | skip:litmus-bindings-fixture:no-script-runner | refused:litmus-bindings-fixture:<reason>

local fixture = require "common.fixture"
local T = fixture.new("litmus-bindings-fixture")
local ROOT = fixture.repo_root()
local GATE = ROOT .. "/scripts/lua/check-litmus-bindings.lua"
if not fs.exists("scripts/lua/check-litmus-bindings.lua") then T:refuse("gate-not-found", GATE) end
local PLAN = fixture.plan_binary()
if PLAN == "" then T:skip("no-script-runner") end
local caps = T:run{ PLAN, "capabilities", timeout_ms = 30000 }
if not ("\n" .. (caps.stdout or "") .. "\n"):find("\nscript\n", 1, true) then T:skip("no-script-runner") end

local LP = "litmus"   -- composed prefix; never written literally next to a fixture name
local tmp = (env.get("TMPDIR") or "/tmp"):gsub("/+$", "")
local SROOT = scratch.declare(tmp .. "/litmus-bindings-fixture-" .. tostring(time.now_ms()))
-- Each case dir joins T.dirs, so the kit's cleanup (finish, refuse) removes it through this
-- declared root; the root itself is an empty dir, removed after.
local function mkcase(name)
    T.dirs[#T.dirs + 1] = { leaf = name }
    return fixture.plain_path(scratch.mkdir(name))
end
local function put(path, content)
    T:must{ "mkdir", "-p", (path:gsub("/[^/]*$", "")) }
    T:must{ "tee", path, stdin = content }
end
-- Never `rm -r` outside the workspace (the runner's rm policy refuses it): a file, then its dir.
local function rm_spec(d, dir_too)
    T:must{ "rm", "-f", d .. "/openspec/specs/fix/spec.md" }
    if dir_too then T:must{ "rmdir", d .. "/openspec/specs/fix" } end
end
local function read_abs(path) return T:run{ "cat", path }.stdout or "" end

local function scaffold(d)
    put(d .. "/openspec/litmus-tests/litmus-fix-bound.yaml", "name: " .. LP .. ":fix-bound\nspec: fix\n")
    put(d .. "/openspec/litmus-tests/litmus-fix-retired.yaml", "name: " .. LP .. ":fix-retired\nphase: retired\n")
    put(d .. "/openspec/litmus-tests/litmus-fix-grand.yaml", "name: " .. LP .. ":fix-grand\nspec: fix\n")
    put(d .. "/openspec/litmus-tests/unbound-grandfathered.txt", "# ratchet\n" .. LP .. ":fix-grand\n")
    put(d .. "/openspec/litmus-bindings.yaml", "specs:\n- spec_id: fix\n  litmus_tests:\n  - " .. LP .. ":fix-bound\n")
    put(d .. "/openspec/specs/fix/spec.md", "# spec: fix\n")
end
-- -> rc, trimmed stdout, stderr
local function run_gate(d)
    local r = T:run{ PLAN, "script", "run", GATE, cwd = ROOT, env = { LITMUS_BINDINGS_ROOT = d },
        env_unset = { "TILLANDSIAS_REPO_ROOT" }, timeout_ms = 120000 }
    return r.code, text.trim(r.stdout or ""), r.stderr or ""
end
local function both(o, e) return o .. "\n" .. e end
local OKPAT = "^ok:" .. LP .. "%-bindings:files=%d+ bound=%d+ retired=%d+ grandfathered=%d+ spec_ids=%d+ resolved=%d+ spec%-grandfathered=%d+$"

-- case 1
local d = mkcase("grammar"); scaffold(d)
local rc, o, e = run_gate(d)
T:arm("case 1 — the ok verdict carries all four counts, on a bounded corpus", rc == 0 and o:find(OKPAT) ~= nil,
    "rc=" .. tostring(rc) .. " '" .. o .. "'")

-- case 2
d = mkcase("clean"); scaffold(d)
rc, o = run_gate(d)
T:arm("case 2 — bound, retired, and grandfathered each counted once", rc == 0 and o ==
    "ok:" .. LP .. "-bindings:files=3 bound=1 retired=1 grandfathered=1 spec_ids=1 resolved=1 spec-grandfathered=0",
    "rc=" .. tostring(rc) .. " '" .. o .. "'")

-- case 3 NEGATIVE CONTROL: a NEW unbound file refuses
d = mkcase("stray"); scaffold(d)
put(d .. "/openspec/litmus-tests/litmus-fix-new-stray.yaml", "name: " .. LP .. ":fix-new-stray\nspec: fix\n")
rc, o = run_gate(d)
T:arm("case 3 — a new unbound litmus file is refused by name",
    rc == 1 and o == "violation:unbound-" .. LP .. ":" .. LP .. ":fix-new-stray", "rc=" .. tostring(rc) .. " '" .. o .. "'")

-- case 4 NEGATIVE CONTROL: a dangling binding refuses
d = mkcase("dangling"); scaffold(d)
local bpath = d .. "/openspec/litmus-bindings.yaml"
put(bpath, read_abs(bpath) .. "  - " .. LP .. ":fix-ghost\n")
rc, o = run_gate(d)
T:arm("case 4 — a binding with no file behind it is refused by name",
    rc == 1 and o == "violation:dangling-binding:" .. LP .. ":fix-ghost", "rc=" .. tostring(rc) .. " '" .. o .. "'")

-- case 5: retirement is honored even when unlisted
d = mkcase("retired"); scaffold(d)
put(d .. "/openspec/litmus-tests/litmus-fix-shelved.yaml", "name: " .. LP .. ":fix-shelved\nphase: retired\n")
rc, o = run_gate(d)
T:arm("case 5 — phase: retired is the sanctioned unbound state", rc == 0 and o ==
    "ok:" .. LP .. "-bindings:files=4 bound=1 retired=2 grandfathered=1 spec_ids=1 resolved=1 spec-grandfathered=0",
    "rc=" .. tostring(rc) .. " '" .. o .. "'")

-- case 6 (1356-vv5m): a spec_id that resolves to NOTHING is refused
d = mkcase("absent-spec"); scaffold(d)
rm_spec(d, true)
rc, o, e = run_gate(d)
T:arm("case 6 — a binding whose spec_id resolves to nothing is refused by name",
    rc ~= 0 and both(o, e):find("violation:binding-names-absent-spec:fix", 1, true) ~= nil,
    "rc=" .. tostring(rc) .. " '" .. both(o, e) .. "'")

-- case 7 (1356-vv5m): resolve to spec.md, not to the directory
d = mkcase("empty-specdir"); scaffold(d)
rm_spec(d, false)
rc, o, e = run_gate(d)
T:arm("case 7 — an empty spec directory does not count as a resolved spec", rc ~= 0,
    "rc=" .. tostring(rc) .. " '" .. both(o, e) .. "'")

-- case 8 (1356-vv5m): the population control. No bound file on purpose (see the .sh).
d = mkcase("no-specids")
put(d .. "/openspec/litmus-tests/litmus-fix-retired.yaml", "name: " .. LP .. ":fix-retired\nphase: retired\n")
put(d .. "/openspec/litmus-tests/litmus-fix-grand.yaml", "name: " .. LP .. ":fix-grand\nspec: fix\n")
put(d .. "/openspec/litmus-tests/unbound-grandfathered.txt", "# ratchet\n" .. LP .. ":fix-grand\n")
put(d .. "/openspec/litmus-bindings.yaml", "specs:\n")
rc, o, e = run_gate(d)
T:arm("case 8 — zero parsed spec_ids is refused, not reported as clean",
    rc ~= 0 and both(o, e):find("litmus-bindings-spec-population-empty", 1, true) ~= nil,
    "rc=" .. tostring(rc) .. " '" .. both(o, e) .. "'")

-- case 9 (1356-vv5m): the ratchet survives
d = mkcase("gf-spec"); scaffold(d)
rm_spec(d, true)
put(d .. "/openspec/litmus-tests/unresolved-grandfathered.txt", "# known stray\nfix\n")
rc, o = run_gate(d)
T:arm("case 9 — a declared unresolved spec_id is exempt and counted as such",
    rc == 0 and o:find("spec_ids=1 resolved=0 spec-grandfathered=1", 1, true) ~= nil,
    "rc=" .. tostring(rc) .. " '" .. o .. "'")

-- case 10 (1570-qutp): a missing base ref is a NAMED skip, never silence
d = mkcase("no-base"); scaffold(d)
rc, o, e = run_gate(d)
local named = false
for l in (e .. "\n"):gmatch("([^\n]*)\n") do
    if l:sub(1, #"  skip:litmus-bindings:no-base-ref:") == "  skip:litmus-bindings:no-base-ref:" then named = true end
end
T:arm("case 10 — no base ref names the skipped diff-scoped checks instead of silence", rc == 0 and named,
    "rc=" .. tostring(rc) .. " out='" .. o .. "' err='" .. e .. "'")

T:cleanup()
T:run{ "rmdir", SROOT }
T:finish()
