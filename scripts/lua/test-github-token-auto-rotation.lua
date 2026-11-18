-- @env PATH HOME
-- @trace order:2080-zcur
--
-- test-github-token-auto-rotation.lua — the host rotates the GitHub token pair
-- on its own (vault_bootstrap::tests::github_token_auto_rotation_*). One arm
-- per named unit test: each must have RUN and passed.
-- Keeps the established verdict line the litmus greps:
--   ok:github-token-auto-rotation:<pass>/<total> | violation:github-token-auto-rotation:<pass>/<total>:cargo_rc=<rc>
-- Ported from scripts/test-github-token-auto-rotation.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-github-token-auto-rotation.lua

local fixture = require "common.fixture"
local T = fixture.new("github-token-auto-rotation")
local ARMS = {
    "github_token_auto_rotation_due_token_rotates_once_refresh_first",
    "github_token_auto_rotation_concurrent_checks_exchange_once",
    "github_token_auto_rotation_not_due_makes_no_exchange",
    "github_token_auto_rotation_rejected_refresh_keeps_the_old_pair",
    "github_token_auto_rotation_needs_no_session_and_refuses_in_a_forge",
    "github_token_auto_rotation_backoff_is_bounded",
    "github_token_auto_rotation_scheduler_starts_once_per_process",
    "github_token_auto_rotation_refresh_expiry_warns_once_a_day",
}
local E = { PATH = env.get("PATH") or "/usr/bin:/bin", HOME = env.get("HOME") or "" }
if proc.run{ argv = { "which", "cargo" }, env = E }.code ~= 0 then T:skip("no-cargo") end

local r = T:run{ "cargo", "test", "-p", "tillandsias-headless", "--features", "tray,listen-vsock", "--bins",
    "github_token_auto_rotation_", cwd = fixture.repo_root(), timeout_ms = 1800000, env = E }
local o = (r.stdout or "") .. (r.stderr or "")
for _, a in ipairs(ARMS) do
    local hit = false
    for _, l in ipairs(text.lines(o)) do
        if l == "test vault_bootstrap::tests::" .. a .. " ... ok" then hit = true end
    end
    T:arm(a, hit, "not run or not ok")
end
if r.code ~= 0 then
    T:arm("cargo test exits 0", false, "rc=" .. tostring(r.code) .. "\n" .. o:sub(-1200))
end
local total = #ARMS
T:finish{
    ok = function(p) return "ok:github-token-auto-rotation:" .. p .. "/" .. total end,
    fail = function(n) return "violation:github-token-auto-rotation:" .. (total - n) .. "/" .. total .. ":cargo_rc=" .. tostring(r.code) end,
}
