-- @env PATH HOME
-- @trace order:1395-88tp, order:1670-gcwu, order:1380-u7sq, order:2359-a3c5
--
-- test-centicolon-grade.lua — centicolon-grade.sh earns positively_tested only for an obligation
-- whose litmus is enforced, bound, not retired, and green for the bytes that are there now.
-- Ported from the .sh of the same name (2359-a3c5). A scratch corpus of four requirements; the timing
-- log is written by the fixture.
--
--   A enforced, bound, green: positively_tested    B unbound, C retired, D unenforced: traced
--   E an unknown req-id is refused by name         V the verdict line
--   M1 no record, M2 other bytes, M3 a later fail, M4 an older spec: A is un-earned
--   Z no key resolves: unmeasured, never ok        O an out dir outside the root, and its remedy
--   P a predicate that dies is named, with its stderr       R the real corpus agrees with itself
--
-- Usage: tillandsias-plan script run scripts/lua/test-centicolon-grade.lua
-- Verdict: ok:centicolon-grade:<n> arms | violation:... | skip:centicolon-grade:...

local fixture = require "common.fixture"
local T = fixture.new("centicolon-grade")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:skip("no-plan-binary") end
local caps = T:run{ PLAN, "capabilities" }
if not text.contains("\n" .. (caps.stdout or ""), "\npredicate\n") then T:skip("plan-binary-lacks-predicate-verb") end
local L, REQS = "lit" .. "mus:", { "a", "b", "c", "d" } -- COMPOSED: these names claim no pin (721-77yu)

local function corpus(keys)
    local d = T:scratch()
    fs.mkdir(d.rel .. "/openspec/specs/alpha"); fs.mkdir(d.rel .. "/openspec/litmus-tests")
    local s = "status: active\n\n"
    for _, x in ipairs(REQS) do s = s .. "### Requirement: Req " .. x .. "\n<!-- req-id: aaaa000" .. x .. " -->\n\n#### Scenario: Scenario " .. x .. "\n\n" end
    fs.write(d.rel .. "/openspec/specs/alpha/spec.md", s)
    local b = "version: '1.0'\nspecs:\n- spec_id: alpha\n  status: active\n  litmus_tests:\n"
    for _, n in ipairs{ "a", "c", "d", "e" } do b = b .. "  - " .. L .. n .. "-file\n" end
    fs.write(d.rel .. "/openspec/litmus-bindings.yaml", b)
    fs.write(d.rel .. "/openspec/litmus-tests/unbound-grandfathered.txt", "")
    local function lt(n, phase, req, enforced)
        fs.write(d.rel .. "/openspec/litmus-tests/litmus-" .. n .. ".yaml", "name: " .. L .. n .. "-file\nspec: alpha\nphase: " .. phase .. "\nsize: instant\ncritical_path:\n  - step: \"the step\"\n"
            .. (keys and "    requirement: " .. req .. "\n" or "") .. '    command: "true"\n' .. (enforced and "    assert_exit: 0\n" or '    expected_behavior: "it works"\n'))
    end
    lt("a", "pre-build", "aaaa000a", true); lt("b", "pre-build", "aaaa000b", true); lt("c", "retired", "aaaa000c", true)
    lt("d", "pre-build", "aaaa000d", false); lt("e", "pre-build", "ffff9999", true)
    return d
end
local function sha(path)
    local r = T:run{ SH, "-s", "--", path, stdin = 'if command -v sha256sum >/dev/null 2>&1; then sha256sum <"$1"; else shasum -a 256 <"$1"; fi\n' }
    return (r.stdout or ""):match("^%x+")
end
local H = corpus(true)
local DA, DS = sha(H.abs .. "/openspec/litmus-tests/litmus-a.yaml"), sha(H.abs .. "/openspec/specs/alpha/spec.md")
local OTHER = ("0"):rep(64)
local logs = T:scratch()
local function rec(status, digest, ts, spec)
    return '{"ts":"' .. ts .. '","host":"fixture","step":"' .. L .. 'a-file","phase":"pre-build","duration_ms":1,"exit":0,"status":"' .. status .. '","digest":"' .. digest
        .. '","regime":"linux","spec":"alpha","spec_digest":"' .. (spec or DS) .. '"}\n'
end
local T1, T2 = "2026-09-26T01:00:00Z", "2026-09-26T02:00:00Z"
-- opts: dir (TILLANDSIAS_CENTICOLON_DIR), plan
local function grade(root, log, opts)
    opts = opts or {}
    fs.write(logs.rel .. "/log.jsonl", log)
    local r = proc.run{ argv = { SH, ROOT .. "/scripts/centicolon-grade.sh" }, cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 300000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = opts.plan or PLAN, TILLANDSIAS_REPO_ROOT = root, TILLANDSIAS_TIMING_LOG = root and logs.abs .. "/log.jsonl" or nil, TILLANDSIAS_CENTICOLON_DIR = opts.dir } }
    local o = "\n" .. ((r.stdout or "") .. (r.stderr or "")):gsub("\r", "")
    return o, "rc=" .. tostring(r.code) .. " " .. o:sub(1, 600)
end
local function result(d) return json.parse(fs.read(d.rel .. "/target/centicolon/grade.json")) end
local function state(d, x)
    for _, ob in ipairs(result(d).obligations) do
        if ob.req_id == "aaaa000" .. x then return ob.state .. "/" .. tostring(ob.reason) end
    end
    return "absent"
end
local GREEN = rec("pass", DA, T1)
local o, why = grade(H.abs, GREEN)
for _, r in ipairs{ { "A enforced, bound and green for its bytes", "a", "positively_tested/green" }, { "B an unbound file", "b", "traced/inert:unbound" }, { "C a retired file", "c", "traced/inert:retired" }, { "D expected_behavior only", "d", "traced/unenforced" } } do
    local got = state(H, r[2])
    T:arm(r[1] .. " is " .. r[3], got == r[3], got .. " " .. why)
end
T:arm("E an unknown req-id is refused by name and the grade is still computed", text.contains(o, "\nwarn:centicolon-grade:violation:centicolon-requirement-unresolved:openspec/litmus-tests/litmus-e.yaml:1:ffff9999\n"), why)
T:arm("V the verdict line", text.contains(o, "\nok:centicolon-grade:R=3 satisfied=1 denominator=4 declared=0 traced=3 positively_tested=1 records=1\n"), why)
T:arm("V grade.json says it was measured", result(H).measured == true, why)
for _, r in ipairs{ { "M1 its record deleted", "", "traced/unrun" }, { "M2 a green record for other bytes", rec("pass", OTHER, T1), "traced/unrun" },
    { "M3 a later fail for the same bytes", GREEN .. rec("fail", DA, T2), "traced/failed" }, { "M4 a green run against an older spec", rec("pass", DA, T1, OTHER), "traced/spec-changed" } } do
    _, why = grade(H.abs, r[2])
    local got = state(H, "a")
    T:arm(r[1] .. " un-earns A: " .. r[3], got == r[3], got .. " " .. why)
end
local Z = corpus(false)
o, why = grade(Z.abs, "")
T:arm("Z no resolved key is unmeasured by name and never ok", text.contains(o, "\nwarn:centicolon-grade:zero-resolved-requirement-keys:files=5\n") and not text.contains(o, "\nok:centicolon-grade:")
    and o:find("\nunmeasured:centicolon%-grade:R=4 satisfied=0 denominator=4 declared=4 [^\n]* reason=zero%-resolved%-requirement%-keys\n") ~= nil, why)
T:arm("Z grade.json says so, with the reason", result(Z).measured == false and result(Z).unmeasured_reason == "zero-resolved-requirement-keys", tostring(result(Z).unmeasured_reason))
local outside = logs.abs .. "/outside-out"
o, why = grade(H.abs, GREEN, { dir = outside })
T:arm("O an out dir outside the root is refused before anything is written", text.contains(o, "\nblocked:centicolon-grade:out-dir-outside-root:" .. outside .. "\n") and text.contains(o, "\n  why: ") and not fs.exists(logs.rel .. "/outside-out"), why)
local remedy = o:match("\n  remedy: [^\n]-TILLANDSIAS_CENTICOLON_DIR=([^ ,;)\n]*)")
if remedy then o, why = grade(H.abs, GREEN, { dir = remedy }) end
T:arm("O its remedy clears it", remedy ~= nil and text.contains(o, "\nok:centicolon-grade:R=3 "), tostring(remedy) .. " " .. why)
fs.write(logs.rel .. "/plan-stub", '#!/usr/bin/env bash\nfor a in "$@"; do case "$a" in */centicolon-grade-static.lua) echo "error: predicate failed: lua vm error: fixture-injected static failure" >&2; exit 1 ;; esac; done\nexec "' .. PLAN .. '" "$@"\n')
T:must{ "chmod", "+x", logs.abs .. "/plan-stub" }
o, why = grade(H.abs, GREEN, { plan = logs.abs .. "/plan-stub" })
T:arm("P a predicate that dies is named in the blocked reason", o:find("\nblocked:centicolon%-grade:static:[^\n]*fixture%-injected static failure") ~= nil, why)
local se = o:match("\n  remedy: [^\n]- ([^ \n]*centicolon%-grade%-static%.stderr)")
local full = se and (se:sub(1, 1) == "/" and se or H.abs .. "/" .. se)
local rel = full and full:sub(1, #H.abs) == H.abs and H.rel .. full:sub(#H.abs + 1)
T:arm("P its remedy names a file that holds the stderr", rel and fs.exists(rel) and text.contains(fs.read(rel), "fixture-injected static failure") or false, tostring(se) .. " " .. why)
local RD = T:scratch("real")
o, why = grade(nil, "", { dir = RD.rel })
local keys = fs.exists(RD.rel .. "/static.json") and json.parse(fs.read(RD.rel .. "/static.json")).resolved_keys
local verdict_word = o:match("\n(%a+):centicolon%-grade:R=")
T:arm("R the real corpus: ok when keys resolved, unmeasured when none did", keys ~= nil and keys ~= false and verdict_word == (keys == 0 and "unmeasured" or "ok"), "keys=" .. tostring(keys) .. " " .. why)
T:finish()
