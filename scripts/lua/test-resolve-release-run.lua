-- @trace order:2080-zcur
--
-- test-resolve-release-run.lua — scripts/resolve-release-run.sh turns `gh`'s
-- answer for a tag's release workflow run into one verdict line, and never
-- reads an empty, null or failed answer as a run id. Twin of
-- test-resolve-open-pr.lua; a stub gh (GH=) prints a fixed answer.
--   no-run-empty-output, no-run-null-output, gh-failed, run-resolves,
--   trailing-newline-tolerated, no-tag-given
-- Ported from scripts/test-resolve-release-run.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-resolve-release-run.lua
-- Verdict: ok:resolve-release-run:<n> arms | violation:resolve-release-run:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("resolve-release-run")
local RESOLVER = fixture.repo_root() .. "/scripts/resolve-release-run.sh"
local W = T:scratch()
local TAG = "v0.4.260813.1"

local function scenario(name, answer, gh_rc, want_rc, want, args)
    fs.write(W.rel .. "/answer", answer)
    fs.write(W.rel .. "/gh", '#!/usr/bin/env bash\ncat "' .. W.abs .. '/answer"\nexit ' .. gh_rc .. "\n")
    T:must{ "chmod", "+x", W.abs .. "/gh" }
    local argv = { RESOLVER }
    for _, a in ipairs(args or { TAG }) do argv[#argv + 1] = a end
    argv.env = { GH = W.abs .. "/gh" }
    local r = T:run(argv)
    local out = text.trim((r.stdout or "") .. (r.stderr or ""))
    local rc_ok = (want_rc == "nonzero") and r.code ~= 0 or r.code == want_rc
    T:arm(name, rc_ok and out == want,
        "exit=" .. tostring(r.code) .. " expected=" .. tostring(want_rc) .. " out='" .. out .. "' want='" .. want .. "'")
end

scenario("no-run-empty-output", "", 0, 1, "blocked:release-run:no-run-for-tag:" .. TAG)
scenario("no-run-null-output", "null", 0, 1, "blocked:release-run:no-run-for-tag:" .. TAG)
scenario("gh-failed", "", 1, 1, "blocked:release-run:gh-failed:" .. TAG)
scenario("run-resolves", "17482930571", 0, 0, "ok:release-run:17482930571")
scenario("trailing-newline-tolerated", "17482930571\n", 0, 0, "ok:release-run:17482930571")
scenario("no-tag-given", "17482930571", 0, "nonzero", "blocked:release-run:no-tag-given", {})
T:finish()
