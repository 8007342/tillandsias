-- @trace order:2080-zcur
--
-- test-resolve-open-pr.lua — scripts/resolve-open-pr.sh turns `gh`'s answer
-- for the open linux-next -> main PR into one verdict line, and never reads an
-- empty or failed answer as a PR. A stub gh (GH=) prints a fixed answer.
--   no-pr-null-output, no-pr-empty-output, gh-failed, pr-resolves,
--   trailing-newline-tolerated
-- Ported from scripts/test-resolve-open-pr.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-resolve-open-pr.lua
-- Verdict: ok:resolve-open-pr:<n> arms | violation:resolve-open-pr:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("resolve-open-pr")
local RESOLVER = fixture.repo_root() .. "/scripts/resolve-open-pr.sh"
local W = T:scratch()

local function scenario(name, answer, gh_rc, want_rc, want)
    fs.write(W.rel .. "/answer", answer)
    fs.write(W.rel .. "/gh", '#!/usr/bin/env bash\ncat "' .. W.abs .. '/answer"\nexit ' .. gh_rc .. "\n")
    T:must{ "chmod", "+x", W.abs .. "/gh" }
    local r = T:run{ RESOLVER, "main", "linux-next", env = { GH = W.abs .. "/gh" } }
    local out = text.trim((r.stdout or "") .. (r.stderr or ""))
    T:arm(name, r.code == want_rc and out == want,
        "exit=" .. tostring(r.code) .. " expected=" .. want_rc .. " out='" .. out .. "' want='" .. want .. "'")
end

scenario("no-pr-null-output", "null", 0, 1, "blocked:open-pr:none-open:linux-next->main")
scenario("no-pr-empty-output", "", 0, 1, "blocked:open-pr:none-open:linux-next->main")
scenario("gh-failed", "", 1, 1, "blocked:open-pr:gh-failed:linux-next->main")
scenario("pr-resolves", "81", 0, 0, "ok:open-pr:81")
scenario("trailing-newline-tolerated", "81\n", 0, 0, "ok:open-pr:81")
T:finish()
