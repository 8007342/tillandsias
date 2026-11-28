-- @trace order:1908-9q4c
--
-- test-glossary-retired-synonyms.lua — pins
-- scripts/lua/check-glossary-retired-synonyms.lua over scratch repos whose
-- base branch is their first commit:
--
--   0 PREMISE    the scratch glossary retires "build stamp", so the arms test
--                the check and not an empty phrase list
--   1 ADDED      an ADDED "Build Stamp" line is flagged at docs/a.md:2 naming
--                "gate stamp", and still exits 0 (advisory)
--   2 UNCHANGED  negative control: the same phrase on an unchanged base line is silent
--   3 CANONICAL  "gate stamp" on an added line is silent
--   4 UNTRACKED  an untracked new file is read whole
--   5 WORD       "build stamped" is not "build stamp": whole words only
--   6 REAL       the real methodology/glossary.yaml yields a non-empty phrase list
--   7 NO-BASE    a base that does not exist is named base-unavailable
--   M1-M3        mutants of the decider, each asserted to land exactly once:
--                M1 reads every line instead of added lines (arm 2's shape flags),
--                M2 drops the lowercasing (arm 1's "Build Stamp" goes silent),
--                M3 drops the word boundary (arm 5's "stamped" flags)
--
-- PRE-FIX RESULT: FAILS — the decider did not exist (the .sh it replaces was
-- never wired, and is deleted in the same commit).
--
-- Verdict: ok:glossary-retired-synonyms-fixture:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("glossary-retired-synonyms-fixture")
local ROOT = fixture.repo_root()
local GUARD_REL = "scripts/lua/check-glossary-retired-synonyms.lua"
local GUARD_SRC = fs.read(ROOT .. "/" .. GUARD_REL)
if not GUARD_SRC then T:refuse("no-decider", GUARD_REL .. " is missing") end

local PB = fixture.plan_binary()
if PB == "" then T:refuse("no-plan-binary", "plan-binary-probe resolved nothing") end

local GLOSSARY = "glossary:\n  retired_synonyms:\n    - {phrase: build stamp, replacement: gate stamp}\n"

-- A scratch repo: base commit holds docs/a.md = `base`; `after` then replaces
-- it (uncommitted), and `extra` is written untracked as docs/new.md.
local function judge(tag, base, after, extra, guard_src, base_ref)
    local repo = T:git_repo(tag)
    proc.run{ argv = { "mkdir", "-p", repo.abs .. "/scripts/lua", repo.abs .. "/methodology", repo.abs .. "/docs" } }
    fs.write(repo.rel .. "/" .. GUARD_REL, guard_src or GUARD_SRC)
    fs.write(repo.rel .. "/methodology/glossary.yaml", GLOSSARY)
    fs.write(repo.rel .. "/docs/a.md", base)
    T:must{ "git", "-C", repo.abs, "add", "-A" }
    T:must{ "git", "-C", repo.abs, "commit", "-q", "-m", "base" }
    T:must{ "git", "-C", repo.abs, "branch", "-f", "base" }
    if after then fs.write(repo.rel .. "/docs/a.md", after) end
    if extra then fs.write(repo.rel .. "/docs/new.md", extra) end
    local r = T:run{ PB, "script", "run", GUARD_REL, cwd = repo.abs, timeout_ms = 120000,
        env = { TILLANDSIAS_GLOSSARY_BASE = base_ref or "base", TILLANDSIAS_GATE_DIFF_BASE = "" } }
    local out = text.trim(r.stdout or "")
    return (r.status == "exited" and r.code or -1), out, (r.stderr or "")
end

local function flagged(err, site) return text.contains(err, site) end

-- 0
T:arm("0 PREMISE the scratch glossary retires \"build stamp\"",
    text.contains(GLOSSARY, "{phrase: build stamp, replacement: gate stamp}"), "")

-- 1
local c1, o1, e1 = judge("one", "base line\n", "base line\nRefresh the Build Stamp after the gate.\n")
T:arm("1 ADDED an added \"Build Stamp\" is flagged at docs/a.md:2 naming \"gate stamp\", rc 0",
    c1 == 0 and o1 == "advisory:glossary-retired-synonyms:1"
        and flagged(e1, 'docs/a.md:2 uses retired "build stamp"; the glossary term is "gate stamp"'),
    "rc=" .. c1 .. " " .. o1 .. " " .. e1:sub(1, 300))

-- 2
local c2, o2, e2 = judge("two", "the old build stamp line\n", "the old build stamp line\na new neutral line\n")
T:arm("2 UNCHANGED the phrase on an unchanged base line is not flagged",
    c2 == 0 and text.starts_with(o2, "ok:glossary-retired-synonyms:"), "rc=" .. c2 .. " " .. o2 .. " " .. e2:sub(1, 300))

-- 3
local c3, o3, e3 = judge("three", "base line\n", "base line\nRefresh the gate stamp after the gate.\n")
T:arm("3 CANONICAL \"gate stamp\" is not flagged",
    c3 == 0 and text.starts_with(o3, "ok:glossary-retired-synonyms:"), "rc=" .. c3 .. " " .. o3 .. " " .. e3:sub(1, 300))

-- 4
local c4, o4, e4 = judge("four", "base line\n", nil, "line one\nwrite the build stamp\n")
T:arm("4 UNTRACKED an untracked file's line is flagged",
    c4 == 0 and flagged(e4, 'docs/new.md:2 uses retired "build stamp"'), "rc=" .. c4 .. " " .. o4 .. " " .. e4:sub(1, 300))

-- 5
local c5, o5, e5 = judge("five", "base line\n", "base line\nthe build stamped image\n")
T:arm("5 WORD \"build stamped\" is not flagged as \"build stamp\"",
    c5 == 0 and text.starts_with(o5, "ok:glossary-retired-synonyms:"), "rc=" .. c5 .. " " .. o5 .. " " .. e5:sub(1, 300))

-- 6
local real = fs.read(ROOT .. "/methodology/glossary.yaml") or ""
local n = 0
for _, l in ipairs(text.lines(real)) do
    if l:match("^%s*%- {phrase: [^,]+, replacement: [^}]+}%s*$") then n = n + 1 end
end
T:arm("6 REAL methodology/glossary.yaml lists retired phrases", n > 0, n .. " phrase(s)")

-- 7
local c7, o7 = judge("seven", "base line\n", "base line\nbuild stamp\n", nil, nil, string.rep("0", 40))
T:arm("7 NO-BASE a missing base is named base-unavailable", c7 == 0 and o7 == "ok:glossary-retired-synonyms:base-unavailable",
    "rc=" .. c7 .. " " .. o7)

-- Mutants: each edit must land exactly once, then the arm it targets must catch it.
local function mutate(from, to)
    local count = 0
    local start = 1
    while true do
        local i, j = GUARD_SRC:find(from, start, true)
        if not i then break end
        count = count + 1
        start = j + 1
    end
    if count ~= 1 then return nil, count end
    local i, j = GUARD_SRC:find(from, 1, true)
    return GUARD_SRC:sub(1, i - 1) .. to .. GUARD_SRC:sub(j + 1), 1
end

local MUTANTS = {
    { id = "M1", what = "every line read, not only added lines",
      from = 'if git({ "git", "ls-files", "--error-unmatch", "--", f }, ROOT) then',
      to = 'if false then',
      case = { "m1", "the old build stamp line\n", "the old build stamp line\na new neutral line\n" },
      caught = function(c, o) return o ~= "" and not text.starts_with(o, "ok:") end },
    { id = "M2", what = "no lowercasing",
      from = 'local low = (lines[ln] or ""):lower()',
      to = 'local low = (lines[ln] or "")',
      case = { "m2", "base line\n", "base line\nRefresh the Build Stamp after the gate.\n" },
      caught = function(c, o) return text.starts_with(o, "ok:") end },
    { id = "M3", what = "no word boundary",
      from = 'if not is_word(line:sub(i - 1, i - 1)) and not is_word(line:sub(j + 1, j + 1)) then return true end',
      to = 'if true then return true end',
      case = { "m3", "base line\n", "base line\nthe build stamped image\n" },
      caught = function(c, o) return text.starts_with(o, "advisory:") end },
}
for _, m in ipairs(MUTANTS) do
    local src, count = mutate(m.from, m.to)
    if not src then
        T:arm(m.id .. " mutant (" .. m.what .. ") lands exactly once", false, "edit matched " .. count .. " time(s)")
    else
        local c, o = judge(m.case[1], m.case[2], m.case[3], nil, src)
        T:arm(m.id .. " mutant (" .. m.what .. ") is caught", c ~= -1 and m.caught(c, o), "rc=" .. c .. " " .. o)
    end
end

T:finish()
