-- @trace order:911-m7js, order:1320-44rs, order:2080-zcur, order:2118-tnut
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

-- ── 2118-tnut: the memo is SHARED by worktrees and keyed on CONTENT ──────
-- A scaffold with a fake plan binary (so its bytes are the fixture's to
-- change), committed, plus a linked worktree of it. No memo override: the
-- arms exercise the real default location, the common git dir.
local W = T:scratch("shared")
for _, d in ipairs{ "scripts", "plan/index.d", "plan/archive", "bin" } do fs.mkdir(W.rel .. "/" .. d) end
for _, s in ipairs{ "archiver-check-memo.sh", "plan-binary-probe.sh", "archive-plan-packets.sh",
    "archive-plan-packets.lua", "archive-plan-packets.rb", "check-archive-answerability.sh",
    "native-scratch-dir.sh" } do
    if fs.exists("scripts/" .. s) then fs.write(W.rel .. "/scripts/" .. s, fs.read("scripts/" .. s)) end
end
fs.write(W.rel .. "/plan/index.yaml", "packets: []\n")
fs.write(W.rel .. "/plan/index.d/20260101t000000z-seed.yaml", "events: []\n")
fs.write(W.rel .. "/bin/plan", "fake plan binary v1\n")
T:must{ "git", "init", "-q", "-b", "main", W.abs }
T:must{ "git", "-C", W.abs, "config", "user.email", "fixture@example.invalid" }
T:must{ "git", "-C", W.abs, "config", "user.name", "fixture" }
T:must{ "git", "-C", W.abs, "config", "commit.gpgsign", "false" }
T:must{ "git", "-C", W.abs, "config", "core.autocrlf", "false" }  -- a Windows autocrlf checkout rewrites the scaffold's bytes
T:must{ "git", "-C", W.abs, "add", "-A" }
T:must{ "git", "-C", W.abs, "commit", "-q", "-m", "scaffold" }
local WT = W.abs .. "/wt2"
T:must{ "git", "-C", W.abs, "worktree", "add", "-q", WT }
local function shared(dir, verb, bin)
    local r = T:run{ "bash", "scripts/archiver-check-memo.sh", verb, cwd = dir,
        env = { TILLANDSIAS_PLAN_BIN = bin or (W.abs .. "/bin/plan") } }
    return text.trim(r.stdout or ""), r
end
-- The linked worktree's binary is the same BYTES at a DIFFERENT path.
fs.mkdir(W.rel .. "/wt2/bin")
fs.write(W.rel .. "/wt2/bin/plan", "fake plan binary v1\n")
local wt_bin = WT .. "/bin/plan"
out = shared(W.abs, "record")
T:arm("main worktree records into the shared memo", text.starts_with(out, "ok:archiver-check-memo-recorded:"), out)
out = shared(WT, "check", wt_bin)
T:arm("a second worktree with identical bytes (binary at another path) hits",
    text.starts_with(out, "ok:archiver-check-memoized:"), out)
fs.write(W.rel .. "/wt2/plan/index.d/20260102t000000z-other.yaml", "events: []\n")
out = shared(WT, "check", wt_bin)
T:arm("the second worktree with a different ledger misses (no vouching across trees)",
    out == "miss:ledger-or-instrument-changed", out)
out = shared(W.abs, "check")
T:arm("the first worktree still hits: the set keeps every verified digest",
    text.starts_with(out, "ok:archiver-check-memoized:"), out)
fs.write(W.rel .. "/bin/plan", "fake plan binary v2\n")
out = shared(W.abs, "check")
T:arm("a rebuilt plan binary at the same path misses (content, not path)",
    out == "miss:ledger-or-instrument-changed", out)
-- 2429-amem: a REAL tillandsias-plan embeds the checkout it was built from (surface_root's
-- env!("CARGO_MANIFEST_DIR")), so two gate worktrees' builds of identical sources differ in bytes
-- and a byte-keyed memo missed on every fresh worktree. The identity is the binary's build-id
-- (a content hash of the sources it compiled), when it can answer one.
fs.write(W.rel .. "/plan/index.d/20260102t000000z-other.yaml", "events: []\n")  -- same ledger both sides
local function stub(path, id, built_at)
    fs.write(path, "#!/bin/sh\n# built from " .. built_at .. "\n"
        .. "[ \"$1\" = build-id ] && { echo 0.1.0+" .. id .. "; exit 0; }\nexit 2\n")
    T:must{ "chmod", "+x", path }
end
stub(W.abs .. "/bin/plan", "aaaa", W.abs)
stub(WT .. "/bin/plan", "aaaa", WT)
out = shared(W.abs, "record")
T:arm("record with a build-id-answering binary", text.starts_with(out, "ok:archiver-check-memo-recorded:"), out)
out = shared(WT, "check", wt_bin)
T:arm("2429 a build of the same sources in another worktree (different bytes, same build-id) hits",
    text.starts_with(out, "ok:archiver-check-memoized:"), out)
stub(WT .. "/bin/plan", "bbbb", WT)
out = shared(WT, "check", wt_bin)
T:arm("2429 CONTROL a binary built from different sources (other build-id) misses",
    out == "miss:ledger-or-instrument-changed", out)
T:must{ "git", "-C", W.abs, "worktree", "remove", "--force", WT }

T:finish()
