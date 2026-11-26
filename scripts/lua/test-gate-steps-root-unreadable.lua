-- @env PATH HOME TOOLBOX_PATH container TILLANDSIAS_SKIP_TOOLBOX TILLANDSIAS_SHARED_TARGET_HELD TILLANDSIAS_SHARED_TARGET CARGO_TARGET_DIR
-- @trace order:2413-39uv
--
-- test-gate-steps-root-unreadable.lua — build.sh --gate-steps refuses a root it cannot enter.
-- Before 2413-39uv `$(cd "$ROOT" && pwd)` turned such a root into "", the glob matched no step,
-- and the run exited 0: a gate that ran nothing read as green (measured on doris, msys: rc=0).
--
--   1 a root that does not exist exits 2 with refused:gate-steps:root-unreadable:<root>
--   2 CONTROL an existing root with an empty gate-steps.d is not refused as unreadable
--
-- On msys build.sh would forward into the WSL2 builder, which cannot read a C:/ root
-- (2413-4e9a), so the fixture runs it bare there (TILLANDSIAS_SKIP_WSL2=1).
-- Usage: tillandsias-plan script run scripts/lua/test-gate-steps-root-unreadable.lua
-- Verdict: ok:gate-steps-root-unreadable:<n> arms | violation:gate-steps-root-unreadable:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-steps-root-unreadable")
local ROOT = fixture.repo_root()
local W = T:scratch()
local ENV = fixture.gate_inherit({})
local SH = fixture.posix_shell()
if SH ~= "bash" then ENV.TILLANDSIAS_SKIP_WSL2 = "1" end
local function gate(root)
    local r = T:run{ SH, "./build.sh", "--gate-steps", root, cwd = ROOT, env = ENV, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 300000 }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end

local missing = W.abs .. "/no-such-root"
local rc, o = gate(missing)
T:arm("1 a root that does not exist exits 2 with refused:gate-steps:root-unreadable",
    rc == 2 and text.contains(o, "refused:gate-steps:root-unreadable:" .. missing), "rc=" .. tostring(rc) .. " " .. o:sub(-400))

fs.mkdir(W.rel .. "/empty/scripts/gate-steps.d")
rc, o = gate(W.abs .. "/empty")
T:arm("2 CONTROL an existing root is not refused as unreadable",
    not text.contains(o, "refused:gate-steps:root-unreadable"), "rc=" .. tostring(rc) .. " " .. o:sub(-400))

T:finish()
