-- @trace spec:spec-traceability, spec:methodology-accountability, order:976-suab, order:2380-psba
-- @env PATH HOME
--
-- test-requirement-ids.lua — the requirement-id stamper (scripts/stamp-requirement-ids.sh)
-- and validator (scripts/lua/check-requirement-ids.lua). Ported from test-requirement-ids.sh
-- (2380-psba); the .sh's eight cases, one arm each.
--
-- IT DRIVES A SCRATCH CORPUS through TILLANDSIAS_SPEC_ROOT, and that is the point: the
-- stamper's first version cd'd to its own root unconditionally and stamped the LIVE specs
-- from a "test". The corpus holds a TOMBSTONED spec that still carries a requirement
-- (exempting tombstones would leave it uncounted forever). No plan binary with `script run`
-- is a loud skip, never a silent pass.
--
--   1  NC: a fresh corpus fails the validator: violation:requirement-ids-missing:3, exit 1
--   2  stamping: "3 new", the validator passes, and the tombstoned requirement is stamped
--   3  IDEMPOTENCE: a second stamp is a no-op and the corpus is byte-identical
--   4  NEVER REASSIGN: a hand-written id survives stamping
--   5  a hand-appended requirement is stamped ("1 new") and existing ids are kept
--   6  a DUPLICATE id is a violation: violation:requirement-ids-duplicated:1, exit 1
--   7  the numbered dialect `### Requirement <n>: ...` without an id is MISSING:1 (1396-35we)
--   8  ... the stamper mints it one 8-hex id, leaves others alone, the validator counts 4,
--      and a second stamp is a no-op
--
-- GRAMMAR ok:requirement-ids-fixture:<n> arms | violation:requirement-ids-fixture:<n>-failed
--       | skip:requirement-ids-fixture:no-script-runner

local fixture = require "common.fixture"
local T = fixture.new("requirement-ids-fixture")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local PLAN = fixture.plan_binary()
if PLAN ~= "" and not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local caps = PLAN ~= "" and (T:run{ PLAN, "capabilities", cwd = ROOT, timeout_ms = 30000 }.stdout or "") or ""
if not ("\n" .. caps .. "\n"):find("\nscript\n", 1, true) then
    T:skip("no-script-runner")
end
local STAMP = ROOT .. "/scripts/stamp-requirement-ids.sh"
local CHECK_LUA = ROOT .. "/scripts/lua/check-requirement-ids.lua"
local W = T:scratch()
local A, B, G = W.rel .. "/openspec/specs/alpha/spec.md", W.rel .. "/openspec/specs/beta/spec.md",
    W.rel .. "/openspec/specs/gamma/spec.md"

local function mkcorpus()
    if fs.exists(W.rel .. "/openspec") then T:must{ "rm", "-rf", W.abs .. "/openspec" } end
    for _, d in ipairs({ "openspec", "openspec/specs", "openspec/specs/alpha", "openspec/specs/beta" }) do
        fs.mkdir(W.rel .. "/" .. d)
    end
    fs.write(A, [[
# alpha Specification

## Requirements

### Requirement: A-1 — the first obligation

The system MUST do the first thing.

### Requirement: A-2 — the second obligation

The system MUST do the second thing.
]])
    fs.write(B, [[
<!-- @tombstone superseded:alpha -->
# beta Specification (Tombstone)

### Requirement: B-1 — a retired obligation that must stay countable
]])
end
local ENV, UNSET = { TILLANDSIAS_SPEC_ROOT = W.abs }, { "TILLANDSIAS_*" }
local function stamp()
    local r = T:run{ SH, STAMP, cwd = ROOT, env = ENV, env_unset = UNSET, timeout_ms = 60000 }
    return (r.stdout or "") .. (r.stderr or "")
end
local function check()
    local r = T:run{ PLAN, "script", "run", CHECK_LUA, cwd = ROOT, env = ENV, env_unset = UNSET, timeout_ms = 60000 }
    return (r.stdout or "") .. (r.stderr or ""), r.code
end
local function has(s, n) return s:find(n, 1, true) ~= nil end
local ID = "<!%-%- req%-id: (%x+) %-%->"
local function corpus() return fs.read(A) .. fs.read(B) end

-- 1
mkcorpus()
local o, rc = check()
T:arm("1 NC: an unstamped corpus fails the validator with 3 missing",
    rc == 1 and has(o, "violation:requirement-ids-missing:3"), "rc=" .. tostring(rc) .. " " .. o)

-- 2
local so = stamp()
o, rc = check()
T:arm("2 stamping makes it pass, and the tombstoned requirement is stamped too",
    has(so, "3 new") and rc == 0 and fs.read(B):find("<!%-%- req%-id: " .. string.rep("%x", 8) .. " %-%->") ~= nil,
    "stamp=[" .. so .. "] rc=" .. tostring(rc) .. " " .. o)

-- 3
local before = corpus()
so = stamp()
T:arm("3 IDEMPOTENCE: a second stamp is a no-op and leaves the corpus byte-identical",
    has(so, "0 new, 3 already had one, 0 file(s) rewritten") and corpus() == before, so)

-- 4
fs.write(B, (fs.read(B):gsub("<!%-%- req%-id: %x* %-%->", "<!-- req-id: deadbeef -->")))
stamp()
T:arm("4 NEVER REASSIGN: a hand-written identifier survives stamping", has(fs.read(B), "req-id: deadbeef"), fs.read(B))

-- 5
local kept = fs.read(A):match("req%-id: %x%x%x%x%x%x%x%x") or "<none>"
fs.write(A, fs.read(A) .. "\n### Requirement: A-3 — added by hand\n")
so = stamp()
T:arm("5 a hand-added requirement is stamped and existing identifiers are kept",
    has(so, "1 new") and has(fs.read(A), kept), "stamp=[" .. so .. "] kept=" .. kept)

-- 6 (first occurrence only)
fs.write(A, (fs.read(A):gsub("<!%-%- req%-id: %x* %-%->", "<!-- req-id: deadbeef -->", 1)))
o, rc = check()
T:arm("6 a duplicate identifier is a violation",
    rc == 1 and has(o, "violation:requirement-ids-duplicated:1"), "rc=" .. tostring(rc) .. " " .. o)

-- 7
mkcorpus()
stamp()
fs.mkdir(W.rel .. "/openspec/specs/gamma")
fs.write(G, "# gamma Specification\n\n### Requirement 1: G-1 — a numbered obligation\n\nThe system MUST do the numbered thing.\n")
o, rc = check()
T:arm("7 a numbered requirement without an id is reported missing (1396-35we)",
    rc == 1 and has(o, "violation:requirement-ids-missing:1"), "rc=" .. tostring(rc) .. " " .. o)

-- 8
local function ids(rel)
    local t = {}
    for l in fs.read(rel):gmatch("[^\n]+") do if has(l, "req-id") then t[#t + 1] = l end end
    return table.concat(t, "\n")
end
local before_alpha = ids(A)
stamp()
local gids = {}
for l in fs.read(G):gmatch("[^\n]+") do
    local id = l:match("^" .. ID .. "$")
    if id then gids[#gids + 1] = id end
end
o, rc = check()
local snap = fs.read(G)
stamp()
local gid = gids[1] or ""
T:arm("8 the numbered heading gets one 8-hex id, nothing else moves, 4 are counted, a re-stamp is a no-op",
    #gids == 1 and #gid == 8 and ids(A) == before_alpha and rc == 0 and has(o, "ok:requirement-ids:4 ")
        and fs.read(G) == snap,
    "gid='" .. table.concat(gids, ",") .. "' rc=" .. tostring(rc) .. " " .. o)

T:finish()
