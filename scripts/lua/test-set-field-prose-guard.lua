-- @trace order:1151-td46, order:642-fedr, order:2380-psba
-- @env PATH HOME
--
-- test-set-field-prose-guard.lua — `plan set-field` on long-form prose must not silently
-- drop lines another host wrote. Ported from test-set-field-prose-guard.sh (2380-psba);
-- same eleven arms.
--
-- HERMETIC, against a THROWAWAY ledger: every arm builds its own plan/ tree in a scratch
-- dir and points the binary at it with --index. A fixture for a guard about clobbering
-- shared prose must not itself clobber shared prose (the first live probe of this change
-- wrote a real fragment onto a real row). No absolute timestamp is encoded: --append stamps
-- the write's own ts, so arms assert old lines survive and the new text is present. What
-- was written is read from the fragment (the fold is 642-fedr's subject).
--
--   1  a value that drops old lines is refused with rc 2 (refused:set-field:would-drop-prose)
--   2  the refusal PRINTS both lines it would have dropped
--   3  a refused write leaves NO fragment (conjoined with rc 2: a tool that never ran also
--      leaves no fragment)
--   4  --replace replaces wholesale, as before
--   5  --append keeps all three old lines
--   6  --append adds the new text
--   7  --append stamps an attribution line naming the writing host
--   8  NC: a short field (priority) is unaffected
--   9  NC: a status write is unaffected
--  10  NC: ADDING a line while keeping every old one verbatim needs no flag (line-exact rule)
--  11  --append with --replace is refused rather than silently picking one
--
-- GRAMMAR ok:set-field-prose-guard:<n> arms | violation:set-field-prose-guard:<n>-failed
--       | refused:set-field-prose-guard:no-plan-binary

local fixture = require "common.fixture"
local T = fixture.new("set-field-prose-guard")
local ROOT = fixture.repo_root()
-- Resolve to an absolute path BEFORE any arm runs in a scratch cwd: a relative one is
-- 127 there, which the .sh's first run reported as ten "the guard did not refuse" arms.
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary", "build one: cargo build --release -p tillandsias-plan") end
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end

local OLD3 = "FIRST LINE, this host's own sentence.\n"
    .. "DO NOT MOVE legacy_tier WITHOUT TELLING YOGA — a downstream grep -m1 makes key order load-bearing.\n"
    .. "VERIFICATION DEBT: the hwfp-v2 field list is unconfirmed on two hosts.\n"

-- A three-line next_action, the shape esme lost three warnings from.
local function ledger()
    local d = T:scratch("l")
    fs.mkdir(d.rel .. "/plan/index.d")
    local body = OLD3:gsub("[^\n]+", "      %0")
    fs.write(d.rel .. "/plan/index.yaml", "packets:\n  - packet_id: a-row-with-shared-prose\n"
        .. "    order: 9999-test\n    status: ready\n    kind: bug\n    priority: p2\n"
        .. "    next_action: |\n" .. body)
    return d
end
local function sf(d, ...)
    local argv = { PLAN, "--index", d.abs .. "/plan/index.yaml", "set-field", ... }
    argv.cwd = d.abs; argv.timeout_ms = 60000
    local r = T:run(argv)
    return (r.stdout or "") .. (r.stderr or ""), tostring(r.code)
end
local function written(d)   -- every fragment set-field recorded, concatenated
    local s = ""
    for _, f in ipairs(fs.list(d.rel .. "/plan/index.d") or {}) do
        s = s .. fs.read(d.rel .. "/plan/index.d/" .. f)
    end
    return s
end
local function first(s) return (s:match("^[^\n]*")) end

-- 1-3. a dropping write is REFUSED and NAMES what it would drop
local d = ledger()
local out, rc = sf(d, "9999-test", "next_action", "one short replacement line", "--host", "yoga")
T:arm("1 a value that drops old lines is refused with rc 2",
    rc == "2" and text.contains(out, "refused:set-field:would-drop-prose"), "rc=" .. rc .. ": " .. first(out))
T:arm("2 the refusal PRINTS the lines it would have dropped, both of them",
    text.contains(out, "DO NOT MOVE legacy_tier") and text.contains(out, "VERIFICATION DEBT"), out)
T:arm("3 a refused write leaves NO fragment behind",
    rc == "2" and #(fs.list(d.rel .. "/plan/index.d") or {}) == 0, "rc=" .. rc .. " fragments=" .. written(d))

-- 4. --replace is the deliberate escape, and it still replaces wholesale
d = ledger()
out, rc = sf(d, "9999-test", "next_action", "one short replacement line", "--replace", "--host", "yoga")
T:arm("4 --replace replaces wholesale, as before", rc == "0", "rc=" .. rc .. ": " .. first(out))

-- 5-7. --append preserves EVERY old line and adds the new text
d = ledger()
out, rc = sf(d, "9999-test", "next_action", "and a fourth line from another host", "--append", "--host", "yoga")
local w = written(d)
local kept = 0
for _, s in ipairs({ "DO NOT MOVE legacy_tier", "VERIFICATION DEBT", "FIRST LINE" }) do
    if text.contains(w, s) then kept = kept + 1 end
end
T:arm("5 --append keeps all three old lines", rc == "0" and kept == 3, "rc=" .. rc .. ", kept " .. kept .. " of 3")
T:arm("6 --append adds the new text", text.contains(w, "and a fourth line from another host"), w)
T:arm("7 --append stamps an attribution line naming the writing host",
    w:find("%[20.*yoga%]") ~= nil, w)

-- 8-9. NEGATIVE CONTROL: short fields are untouched by this guard
d = ledger()
out, rc = sf(d, "9999-test", "priority", "p1", "--host", "yoga")
T:arm("8 NC: a short field (priority) is unaffected", rc == "0", "rc=" .. rc .. ": " .. first(out))
d = ledger()
out, rc = sf(d, "9999-test", "status", "in_progress", "--host", "yoga")
T:arm("9 NC: a status write is unaffected", rc == "0", "rc=" .. rc .. ": " .. first(out))

-- 10. NEGATIVE CONTROL: the subject is DROPPED LINES, not length. Line-exact: editing a
-- line in place counts as dropping it; adding while keeping the old ones verbatim does not.
d = ledger()
out, rc = sf(d, "9999-test", "next_action", OLD3 .. "and a new line that adds to them", "--host", "yoga")
T:arm("10 NC: ADDING a line while keeping every old one verbatim needs no flag", rc == "0",
    "rc=" .. rc .. " — the guard is about dropping, not editing")

-- 11. --append and --replace together are a contradiction, not a preference
d = ledger()
out, rc = sf(d, "9999-test", "next_action", "x", "--append", "--replace", "--host", "yoga")
T:arm("11 --append with --replace is refused rather than silently picking one", rc == "2", "rc=" .. rc)

T:finish()
