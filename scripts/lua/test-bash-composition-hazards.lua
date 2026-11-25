-- @env PATH HOME
-- @trace order:1252-r72q, order:1268-fx87, order:2357-5quw
--
-- test-bash-composition-hazards.lua — the bash composition-hazard lint and its advisory. Ported
-- from the .sh of the same name (2357-5quw). The grammar is pinned by the Rust unit tests beside
-- bash_hazards.rs; this pins what needs repository history and the real tree.
--
--   1 the pre-fix check-seam-writers-canonical.sh pipeline (c7e860ff1) is named, and the lint is
--     silent at its fix (2b777de3e). It never inverted: that script sets only `set -u`.
--   2 NC pipefail in a comment is not counted; set for real it is
--   3 the advisory exits 0 over the live tree
--   4 it counts pipelines, not files
--
-- Usage: tillandsias-plan script run scripts/lua/test-bash-composition-hazards.lua
-- Verdict: ok:bash-composition-hazards:<n> arms | violation:... | skip:bash-composition-hazards:no-binary

local fixture = require "common.fixture"
local T = fixture.new("bash-composition-hazards")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
local BIN = ROOT .. "/target/release/tillandsias-litmus-rust"
if not fs.exists("target/release/tillandsias-litmus-rust") then T:skip("no-binary") end
local d = T:scratch()
local E = { PATH = env.get("PATH"), HOME = env.get("HOME") }
-- COMPOSED: this file holds no hazard of its own for a textual scan to find.
local GQ = "grep " .. "-q"
local function lint(body, ...)
    fs.write(d.rel .. "/x.sh", body)
    local r = proc.run{ argv = { BIN, "bash-hazards", d.abs .. "/x.sh", ... }, cwd = ROOT, env = E, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    return (r.stdout or "") .. (r.stderr or "")
end
-- The COUNT is asserted: the summary prints every shape, at zero too.
local function count(o, shape) return tonumber(o:match(shape:gsub("%p", "%%%0") .. ":pipelines=(%d+)")) end
local function at(rev) return T:run{ "git", "show", rev .. ":scripts/check-seam-writers-canonical.sh", cwd = ROOT } end
local pre, post = at("c7e860ff1"), at("2b777de3e")
if pre.code == 0 and post.code == 0 then
    local o = lint(pre.stdout, "--show")
    T:arm("1a the pre-fix pipeline is named", (count(o, "negated-pipeline-if") or 0) > 0 and text.contains(o, GQ), o)
    o = lint(post.stdout, "--show")
    T:arm("1b silent once it was converted", count(o, "negated-pipeline-if") == 0, o)
else
    out.line("skip: 1 c7e860ff1 or 2b777de3e is not in this clone")
end
local PIPE = "cat /etc/hosts | " .. GQ .. " localhost\n"
local o = lint("#!/usr/bin/env bash\n# This comment says pipefail and that must not count.\nset -u\n" .. PIPE)
T:arm("2a NC pipefail in a comment is not counted", count(o, "pipefail-grep-q") == 0, o)
o = lint("#!/usr/bin/env bash\nset -euo pipefail\n" .. PIPE)
T:arm("2b pipefail that is set is counted once", count(o, "pipefail-grep-q") == 1, o)
local r = proc.run{ argv = { PLAN, "script", "run", "scripts/lua/check-bash-composition-hazards.lua" }, cwd = ROOT, env = E, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 120000 }
o = r.stdout or ""
T:arm("3 the advisory exits 0 over the live tree", r.code == 0, "rc=" .. tostring(r.code) .. " " .. o .. (r.stderr or ""))
local p, f = o:match("pipefail%-grep%-q:pipelines=(%d+):[^\n]-files=(%d+)")
T:arm("4 pipelines exceed files: it is not a per-file scan", p ~= nil and tonumber(p) > tonumber(f), "pipelines=" .. tostring(p) .. " files=" .. tostring(f) .. " " .. o:sub(1, 300))
T:finish()
