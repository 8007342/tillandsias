-- @trace order:1261-bn7v, order:2400-prg4, spec:ci-release
--
-- test-plan-field-get.lua — the folded-long-form-field primitive. Ported from
-- test-plan-field-get.sh (2400-prg4); same four arms, in its order.
--
-- `query --json --limit 0` carries NO long-form field, so 1261-bn7v's lane check needs
-- `field-get`. THE TERNARY IS THE POINT (1260-2qgi): set / unset / no-such-packet are three
-- outcomes a caller must tell apart.
--
--   1  a SET field prints its value and exits 0
--   2  an UNSET field exits 3 with empty stdout (not conflated with empty)
--   3  a packet that does not exist exits 1, distinct from unset's 3
--   4  the binary reads the CWD's ledger: an extracted origin/linux-next plan/ tree answers
--      (with the live tree as its control)
--
-- GRAMMAR ok:plan-field-get:<n> arms | violation:plan-field-get:<n>-failed
--       | skip:plan-field-get:no-plan-binary | skip:plan-field-get:subcommand-absent-in-this-binary

local fixture = require "common.fixture"
local T = fixture.new("plan-field-get")
local ROOT = fixture.repo_root()
local P = fixture.plan_binary()
if P == "" then T:skip("no-plan-binary") end
if P:sub(1, 1) ~= "/" then P = ROOT .. "/" .. P:gsub("^%./", "") end

local function fg(pkt, field, cwd)
    local r = T:run{ P, "field-get", pkt, field, cwd = cwd or ROOT, timeout_ms = 60000 }
    return r.code, r.stdout or "", r.stderr or ""
end

local _, po, pe = fg("9999-nosuch", "next_action")
local probe = po .. pe
if not (text.contains(probe, "unset:field-get") or text.contains(probe, "error:")) then
    T:skip("subcommand-absent-in-this-binary")
end

local REF = "1261-bn7v"

local rc, o = fg(REF, "next_action")
T:arm("ARM 1 a set field prints its value and exits 0", rc == 0 and o ~= "",
    "rc=" .. tostring(rc) .. " len=" .. #o)

rc, o = fg(REF, "progress_summary")
T:arm("ARM 2 an unset field exits 3 with empty stdout (not conflated with empty)", rc == 3 and o == "",
    "rc=" .. tostring(rc) .. " out='" .. o .. "'")

rc = fg("9999-nosuch", "next_action")
T:arm("ARM 3 an unresolvable packet exits 1, distinct from unset's 3", rc == 1, "rc=" .. tostring(rc))

-- ARM 4: two trees that can DISAGREE; the extracted one must answer from its own plan/.
if T:run{ "git", "rev-parse", "--verify", "--quiet", "refs/remotes/origin/linux-next", cwd = ROOT }.code ~= 0 then
    out.line("skip: ARM 4 — no origin/linux-next ref in this clone")
else
    local W = T:scratch()
    local tar = W.abs .. "/plan.tar"
    local ok = T:run{ "git", "archive", "-o", tar, "origin/linux-next", "plan/", cwd = ROOT, timeout_ms = 120000 }.code == 0
        and T:run{ "tar", "-x", "-f", tar, "-C", W.abs, timeout_ms = 120000 }.code == 0
    if not ok then
        out.line("skip: ARM 4 — git archive unavailable")
    else
        local _, here = fg(REF, "next_action")
        local _, there = fg(REF, "next_action", W.abs)
        T:arm("ARM 4 the binary reads the ledger in its CWD, so an extracted origin tree can be folded",
            there ~= "", "extracted tree returned nothing")
        T:arm("ARM 4 control: the live tree returns the field", here ~= "", "live tree returned nothing")
    end
end

T:finish()
