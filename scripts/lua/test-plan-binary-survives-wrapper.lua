-- @env PATH
-- @trace order:1804-sccl, order:2080-zcur
--
-- test-plan-binary-survives-wrapper.lua — land run 185 (#590): the gate died at
-- "no fresh tillandsias-plan resolves" with RUSTC_WRAPPER=scripts/sccache-wrapper.sh
-- in the environment. ensure_fresh_plan_binary rebuilds a stale plan binary with
-- its output sent to /dev/null, so ANY failure of the ambient compiler wrapper
-- surfaced as "no fresh binary". A cache must never red a gate.
--   arm1 (control)  a stub cargo that fails whenever RUSTC_WRAPPER is set
--                   proves the stub models the failure
--   arm2            stale binary + failing wrapper: ensure_fresh_plan_binary still
--                   returns a fresh binary (rebuild retried without the wrapper)
--   arm3            no wrapper set: unchanged, rc 0 on the first build
-- Ported from scripts/test-plan-binary-survives-wrapper.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-plan-binary-survives-wrapper.lua
-- Verdict: ok:plan-binary-survives-wrapper:<n> arms | violation:plan-binary-survives-wrapper:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("plan-binary-survives-wrapper")
local W = T:scratch()
for _, d in ipairs{ "scripts", "bin", "crates/tillandsias-plan/src", "target/release" } do
    fs.mkdir(W.rel .. "/" .. d)
end
fs.write(W.rel .. "/scripts/plan-binary-probe.sh", fs.read("scripts/plan-binary-probe.sh"))
fs.write(W.rel .. "/Cargo.lock", "")
fs.write(W.rel .. "/crates/tillandsias-plan/src/lib.rs", "x\n")
-- models a build that fails only under a compiler wrapper
fs.write(W.rel .. "/bin/cargo", table.concat({
    "#!/bin/sh",
    'if [ -n "${RUSTC_WRAPPER:-}" ]; then echo "sccache: encountered fatal error" >&2; exit 101; fi',
    "printf '#!/bin/sh\\nexit 0\\n' > target/release/tillandsias-plan; chmod +x target/release/tillandsias-plan",
}, "\n") .. "\n")
T:must{ "chmod", "+x", W.abs .. "/bin/cargo" }
local PATH = W.abs .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin")
fs.write(W.rel .. "/refresh.sh", ". scripts/plan-binary-probe.sh\nensure_fresh_plan_binary\n")
local BIN = W.rel .. "/target/release/tillandsias-plan"

local function stale()
    fs.write(BIN, "#!/bin/sh\nexit 0\n")
    T:must{ "chmod", "+x", W.abs .. "/target/release/tillandsias-plan" }
    T:must{ "touch", "-d", "2020-01-01", W.abs .. "/target/release/tillandsias-plan" }
    T:must{ "touch", W.abs .. "/crates/tillandsias-plan/src/lib.rs" }
end
local function refresh(extra)
    local e = { PATH = PATH, R = "release" }
    for k, v in pairs(extra) do e[k] = v end
    return T:run{ "bash", W.abs .. "/refresh.sh", cwd = W.abs, env = e }
end

local c = T:run{ "cargo", "build", cwd = W.abs, env = { PATH = PATH, RUSTC_WRAPPER = "/bin/true" } }
T:arm("arm1 stub cargo fails under a wrapper", c.status == "exited" and c.code ~= 0, "status=" .. tostring(c.status) .. " rc=" .. tostring(c.code))

stale()
local r = refresh{ RUSTC_WRAPPER = "/bin/true" }
T:arm("arm2 failing wrapper does not red the plan binary refresh",
    r.code == 0 and text.trim(r.stdout or "") ~= "",
    "rc=" .. tostring(r.code) .. " out=[" .. text.trim(r.stdout or "") .. "]: a wrapper failure became 'no fresh tillandsias-plan'")

stale()
r = refresh{ A = "1" }
T:arm("arm3 no wrapper: unchanged", r.code == 0 and text.trim(r.stdout or "") ~= "", "rc=" .. tostring(r.code))

T:finish()
