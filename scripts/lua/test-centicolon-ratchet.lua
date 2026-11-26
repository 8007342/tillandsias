-- @env PATH HOME
-- @trace order:1395-ue3i, order:1670-gcwu, order:1528-gxzf, order:2362-2cfp
--
-- test-centicolon-ratchet.lua — the ADVISORY CentiColon R line: printed every run, warns only on a
-- regression, reports added obligations as scope and recorded removals as retired, prints blocked:
-- rather than R=0, and always exits 0. Ported from the .sh of the same name (2362-2cfp).
-- added = scope growth; retired = vanished WITH a record (a registry tombstone, or an
-- openspec/changes note); lost = vanished with none, or a state moving down. Only lost warns.
--
--   1 baseline   2 unchanged: monotone   3 --no-snapshot never swallows the warning
--   4 lost (down), by id   5 added   6 vanished with no record   7 with a changes record
--   8 with a registry tombstone   9-10 a CRLF, mixed-whitespace snapshot reads the same
--   11 an empty grade artifact is blocked   12 no corpus is blocked, never R=0
--   13 an unmeasured grade is not a grade and never becomes the snapshot
--
-- Usage: tillandsias-plan script run scripts/lua/test-centicolon-ratchet.lua
-- Verdict: ok:centicolon-ratchet:<n> arms | violation:... | skip:centicolon-ratchet:...

local fixture = require "common.fixture"
local T = fixture.new("centicolon-ratchet")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:skip("no-plan-binary") end
local caps = T:run{ PLAN, "capabilities" }
if not text.contains("\n" .. (caps.stdout or ""), "\npredicate\n") then T:skip("plan-binary-lacks-predicate-verb") end
local L = "lit" .. "mus:" -- COMPOSED: the name claims no pin (721-77yu)
local H, W = T:scratch(), T:scratch()
local BIND, LAST = H.rel .. "/openspec/litmus-bindings.yaml", H.rel .. "/target/centicolon/last.txt"
fs.mkdir(H.rel .. "/openspec/specs/alpha"); fs.mkdir(H.rel .. "/openspec/litmus-tests")
local function sha(s)
    local r = T:run{ SH, "-s", stdin = "if command -v sha256sum >/dev/null 2>&1; then c=sha256sum; else c='shasum -a 256'; fi\nprintf '%s' '" .. s .. "' | $c\n" }
    return (r.stdout or ""):match("^%x+")
end
local function spec(letters)
    local s = "status: active\n\n"
    for x in letters:gmatch(".") do s = s .. "### Requirement: Req " .. x .. "\n<!-- req-id: aaaa000" .. x .. " -->\n\n#### Scenario: Scenario " .. x .. "\n\n" end
    fs.write(H.rel .. "/openspec/specs/alpha/spec.md", s)
end
local LITMUS = "name: " .. L .. 'a-file\nspec: alpha\nphase: pre-build\nsize: instant\ncritical_path:\n  - step: "s"\n    requirement: aaaa000a\n    command: "true"\n    assert_exit: 0\n'
local function bindings(tail) fs.write(BIND, "version: '1.0'\nspecs:\n- spec_id: alpha\n  status: active\n  litmus_tests:\n  - " .. L .. "a-file\n" .. (tail or "")) end
spec("ab"); bindings()
fs.write(H.rel .. "/openspec/litmus-tests/unbound-grandfathered.txt", "")
fs.write(H.rel .. "/openspec/litmus-tests/litmus-a.yaml", LITMUS)
local hash = T:run{ SH, "-s", "--", H.abs .. "/openspec/litmus-tests/litmus-a.yaml", stdin = 'if command -v sha256sum >/dev/null 2>&1; then sha256sum <"$1"; else shasum -a 256 <"$1"; fi\n' }
local DIGEST = (hash.stdout or ""):match("^%x+")
local function green() fs.write(W.rel .. "/log.jsonl", '{"ts":"2026-09-26T01:00:00Z","host":"fixture","step":"' .. L .. 'a-file","status":"pass","digest":"' .. DIGEST .. '"}\n') end
local function ungreen() fs.write(W.rel .. "/log.jsonl", "") end
local function run(arg, script)
    local argv = { PLAN, "script", "run", script or ROOT .. "/scripts/lua/check-centicolon-ratchet.lua" }
    if arg then argv[5], argv[6] = "--", arg end
    local r = proc.run{ argv = argv, cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 300000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = PLAN, TILLANDSIAS_REPO_ROOT = H.abs, TILLANDSIAS_TIMING_LOG = W.abs .. "/log.jsonl" } }
    local o = "\n" .. ((r.stdout or "") .. (r.stderr or "")):gsub("\r", "")
    local warns = {}
    for w in o:gmatch("\n(warn:centicolon%-ratchet:[^\n]*)") do warns[#warns + 1] = w end
    return { rc = r.code, line = o:match("\n(centicolon:[^\n]*)") or "", warns = warns, warned = table.concat(warns, " | "), why = "rc=" .. tostring(r.code) .. " " .. o:sub(1, 600) }
end
local function says(x, ...)
    if x.rc ~= 0 then return false end
    for _, s in ipairs{ ... } do
        if not text.contains(x.line, s) then return false end
    end
    return true
end
local ID_A, ID_B = "cc:aaaa000a:" .. sha("Scenario a"):sub(1, 8), "cc:aaaa000b:" .. sha("Scenario b"):sub(1, 8)
local function lost(down, id) return "warn:centicolon-ratchet:lost=1:vanished=" .. (down and 0 or 1) .. ",down=" .. (down and 1 or 0) .. ":" .. id end

green()
local x = run()
T:arm("1 the baseline line", x.rc == 0 and x.line == "centicolon: R=1 satisfied=1 denominator=2 added=0 retired=0 lost=0 histogram=declared:1,traced:0,positively_tested:1 regime=baseline (advisory)", x.why)
x = run()
T:arm("2 an unchanged rerun is monotone", says(x, " added=0 retired=0 lost=0 ", " regime=monotone (advisory)"), x.why)
ungreen()
local w1, w2 = run("--no-snapshot"), run("--no-snapshot")
T:arm("3 --no-snapshot reports the loss and does not swallow it", #w1.warns == 1 and #w2.warns == 1, w1.warned .. " / " .. w2.warned)
x = run()
T:arm("4 a lost satisfaction warns by id and exits 0", says(x, " satisfied=0 ", " lost=1 ", " regime=lost (advisory)") and x.warned == lost(true, ID_A), x.why)
green(); run()
spec("abc"); x = run()
T:arm("5 an added requirement is scope, not a warning", says(x, " denominator=3 added=1 retired=0 lost=0 ", " regime=scope-added (advisory)") and #x.warns == 0, x.why)
spec("ac"); x = run()
T:arm("6 one removed with no record is lost (vanished), by id", says(x, " retired=0 lost=1 ") and x.warned == lost(false, ID_B), x.why)
fs.mkdir(H.rel .. "/openspec/changes/drop-c"); fs.write(H.rel .. "/openspec/changes/drop-c/proposal.md", "Removes requirement aaaa000c (Req c).\n")
spec("a"); x = run()
T:arm("7 one removed with an openspec/changes record is retired", says(x, " retired=1 lost=0 ", " regime=retired (advisory)") and #x.warns == 0, x.why)
fs.mkdir(H.rel .. "/openspec/specs/beta")
fs.write(H.rel .. "/openspec/specs/beta/spec.md", "status: active\n\n### Requirement: Beta one\n<!-- req-id: bbbb0001 -->\n\n#### Scenario: B1\n\n#### Scenario: B2\n")
bindings("- spec_id: beta\n  status: active\n  litmus_tests: []\n"); run()
fs.write(H.rel .. "/openspec/specs/beta/spec.md", "status: obsolete\n")
bindings("- spec_id: beta\n  tombstone: superseded:alpha\n  status: active\n  litmus_tests: []\n"); x = run()
T:arm("8 a spec obsoleted with a registry tombstone is retired", says(x, " retired=2 lost=0 ", " regime=retired (advisory)") and #x.warns == 0, x.why)
-- The snapshot respelled: mixed blanks and CRLF, the same four fields.
local function mangle(lead)
    fs.write(LAST, (fs.read(LAST):gsub("([^\n]+)\n", function(l)
        local f = {}
        for w in l:gmatch("%S+") do f[#f + 1] = w end
        return lead .. table.concat(f, "\t", 1, 2) .. "  " .. (f[3] or "") .. "\t" .. (f[4] or "") .. "\r\n"
    end)))
end
green(); run(); ungreen(); mangle(" \t"); x = run("--no-snapshot")
T:arm("9 a CRLF, mixed-whitespace snapshot still shows a downgrade", says(x, " regime=lost (advisory)") and x.warned == lost(true, ID_A), x.why)
green(); run(); mangle("\t"); x = run("--no-snapshot")
T:arm("10 and is monotone when nothing changed", says(x, " regime=monotone (advisory)") and #x.warns == 0, x.why)

fs.mkdir(W.rel .. "/scripts/lua")
fs.write(W.rel .. "/scripts/lua/check-centicolon-ratchet.lua", fs.read("scripts/lua/check-centicolon-ratchet.lua"))
local PORT = W.abs .. "/scripts/lua/check-centicolon-ratchet.lua"
local function graded(artifact, says_)
    fs.write(W.rel .. "/scripts/centicolon-grade.sh", "#!/usr/bin/env bash\nmkdir -p \"$TILLANDSIAS_REPO_ROOT/target/centicolon\"\nprintf '%s' '" .. artifact .. "' >\"$TILLANDSIAS_REPO_ROOT/target/centicolon/grade.json\"\nprintf '%s\\n' '" .. says_ .. "'\n")
    return run(nil, PORT)
end
local OKV = "ok:centicolon-grade:R=1 satisfied=1 denominator=1 declared=0 traced=0 positively_tested=1 records=1"
x = graded("", OKV)
T:arm("11 an empty grade artifact is blocked, not parsed", x.rc == 0 and x.line == "centicolon: blocked:" .. OKV .. " (advisory)", x.why)
local before = fs.read(LAST)
local UN = "R=4 satisfied=0 denominator=4 declared=4 traced=0 positively_tested=0 records=0 reason=zero-resolved-requirement-keys"
x = graded("{}", "warn:centicolon-grade:zero-resolved-requirement-keys:files=5\nunmeasured:centicolon-grade:" .. UN)
T:arm("13 an unmeasured grade is reported as such and never becomes the snapshot", x.rc == 0 and x.line == "centicolon: unmeasured:" .. UN .. " (advisory)" and fs.read(LAST) == before, x.why)
T:must{ "rm", "-rf", H.abs .. "/openspec/specs" }
x = run()
T:arm("12 no corpus is blocked by the extractor, never R=0", x.rc == 0 and x.line:sub(1, 30) == "centicolon: blocked:extractor:" and not text.contains(x.line, "R=0"), x.why)
T:finish()
