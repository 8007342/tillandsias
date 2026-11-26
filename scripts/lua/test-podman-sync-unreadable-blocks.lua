-- @env PATH HOME
-- @trace order:2416-pscn
--
-- test-podman-sync-unreadable-blocks.lua — check-podman-sync-budgets refuses when its listing names
-- a file it cannot read. Before 2416-pscn each read sat in a pcall that dropped a failure, so an
-- unreadable file counted as zero matches and a real violation under it read ok:podman-sync-bounded:0.
--
--   1 a listed file holding a violation that cannot be read is blocked:...:unreadable (exit 2), never ok
--   2 CONTROL the same violation, readable, is still violation:direct-command:1
--
-- Unreadable is made per host: chmod 000 on Unix; on msys an external /-spelled root, whose files a
-- native reader cannot open. Usage: tillandsias-plan script run scripts/lua/test-podman-sync-unreadable-blocks.lua
-- Verdict: ok:podman-sync-unreadable-blocks:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("podman-sync-unreadable-blocks")
local PLAN, ROOT, SH = fixture.plan_binary(), fixture.repo_root(), fixture.posix_shell()
if PLAN == "" then T:refuse("no-plan-binary") end
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local W = T:scratch()
local BAD = 'fn f() { let c = std::process::Command::new("podman"); }\n'
local function check(search_root, cwd)
    local r = T:run{ PLAN, "script", "run", ROOT .. "/scripts/lua/check-podman-sync-budgets.lua", cwd = cwd or ROOT,
        env = { PODMAN_SYNC_SEARCH_ROOT = search_root }, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 120000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    return r.code, o, "rc=" .. tostring(r.code) .. " " .. o:sub(-300)
end

-- Arm 1: an unreadable listed file.
local rc, o, why
if SH ~= "bash" then
    -- msys: an external root in its /-spelling (as a native parent passes it); find lists it,
    -- and this reader cannot open what it lists.
    local made = T:run{ SH, "-s", "--", BAD, stdin = 'd="$(mktemp -d)" && mkdir -p "$d/src" && printf "%s" "$1" > "$d/src/bad.rs" && printf %s "$d"\n' }
    local ext = text.trim(made.stdout or "")
    rc, o, why = check(ext)
    T:run{ SH, "-s", "--", ext, stdin = 'rm -rf "$1"\n' }
else
    fs.mkdir(W.rel .. "/locked/src"); fs.write(W.rel .. "/locked/src/bad.rs", BAD)
    T:must{ "chmod", "000", W.abs .. "/locked/src/bad.rs" }
    rc, o, why = check(W.abs .. "/locked")
    T:run{ "chmod", "644", W.abs .. "/locked/src/bad.rs" }
end
T:arm("1 an unreadable listed file blocks (exit 2), never ok", rc == 2 and text.contains(o, "blocked:podman-sync-bounded:unreadable:")
    and not text.contains(o, "ok:podman-sync-bounded"), why)

-- Arm 2: CONTROL, readable.
fs.mkdir(W.rel .. "/open/crates/x/src"); fs.write(W.rel .. "/open/crates/x/src/bad.rs", BAD)
local r2 = T:run{ PLAN, "script", "run", ROOT .. "/scripts/lua/check-podman-sync-budgets.lua", cwd = ROOT,
    env = { TILLANDSIAS_REPO_ROOT = W.abs .. "/open", PODMAN_SYNC_SEARCH_ROOT = "crates" }, timeout_ms = 120000 }
local o2 = (r2.stdout or "") .. (r2.stderr or "")
T:arm("2 CONTROL a readable violation is still violation:direct-command:1", text.contains(o2, "violation:direct-command:1"), "rc=" .. tostring(r2.code) .. " " .. o2:sub(-300))
T:finish()
