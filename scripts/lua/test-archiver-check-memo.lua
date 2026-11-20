-- @trace order:911-m7js, order:1320-44rs, order:2080-zcur
--
-- test-archiver-check-memo.lua — the archiver-check memo hits only on an
-- unchanged ledger AND unchanged instrument; a byte in either is a miss.
-- Hermetic: a scratch memo file, and the ledger mutation is a fragment written
-- then removed (fragments are what a drain adds; the memo must miss on one).
--
-- 1320-44rs: all of it happens in a SCAFFOLD — a scratch git repo with a tiny
-- synthetic ledger and copies of the scripts the memo digests — never in the
-- live plan/index.d, where a run killed between the write and the rm left a
-- probe fragment the fold reads as real.
-- Ported from scripts/test-archiver-check-memo.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-archiver-check-memo.lua
-- Verdict: ok:archiver-check-memo:<n> arms | violation:archiver-check-memo:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("archiver-check-memo")
local SC = T:scratch("scaffold")
local MD = T:scratch("memo")
local M = MD.abs .. "/memo"

for _, d in ipairs{ "scripts", "plan/index.d", "plan/archive" } do fs.mkdir(SC.rel .. "/" .. d) end
for _, s in ipairs{ "archiver-check-memo.sh", "plan-binary-probe.sh", "archive-plan-packets.sh",
    "archive-plan-packets.lua", "archive-plan-packets.rb", "check-archive-answerability.sh",
    "native-scratch-dir.sh" } do
    if fs.exists("scripts/" .. s) then fs.write(SC.rel .. "/scripts/" .. s, fs.read("scripts/" .. s)) end
end
fs.write(SC.rel .. "/plan/index.yaml", "packets: []\n")
fs.write(SC.rel .. "/plan/archive/packets-2026-01.yaml", "packets: []\n")
fs.write(SC.rel .. "/plan/index.d/20260101t000000z-seed.yaml", "events: []\n")
T:must{ "git", "-C", SC.abs, "init", "-q", "." }

local function memo(verb)
    local r = T:run{ "bash", "scripts/archiver-check-memo.sh", verb, cwd = SC.abs,
        env = { TILLANDSIAS_ARCHIVER_MEMO = M } }
    return text.trim(r.stdout or ""), r
end

local out, r = memo("check")
T:arm("no memo -> miss:no-memo", r.code ~= 0 and out == "miss:no-memo", out)
out = memo("record")
T:arm("record writes the memo", text.starts_with(out, "ok:archiver-check-memo-recorded:"), out)
out = memo("check")
T:arm("unchanged ledger -> hit", text.starts_with(out, "ok:archiver-check-memoized:"), out)
fs.write(SC.rel .. "/plan/index.d/zz-archiver-memo-probe.yaml", "# probe\nevents: []\n")
out = memo("check")
T:arm("a new fragment -> miss", out == "miss:ledger-or-instrument-changed", out)
T:must{ "rm", "-f", SC.abs .. "/plan/index.d/zz-archiver-memo-probe.yaml" }
out = memo("check")
T:arm("fragment removed -> hit again (digest is content, not time)",
    text.starts_with(out, "ok:archiver-check-memoized:"), out)
local d1 = memo("digest")
T:arm("digest is a sha256", #d1 == 64 and d1:match("^%x+$") ~= nil, d1)

T:finish()
