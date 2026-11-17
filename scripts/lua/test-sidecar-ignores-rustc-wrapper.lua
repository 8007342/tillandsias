-- @trace order:1804-sccl, order:2099-f982
-- @env CARGO_TARGET_DIR
--
-- test-sidecar-ignores-rustc-wrapper.lua — the musl release/LTO sidecar build
-- must not run under the ambient RUSTC_WRAPPER. Land run 181 died with
-- "sccache ... (exit status: 254)" on `-C linker-plugin-lto --target
-- x86_64-unknown-linux-musl`. A wrapper that always exits 254 models that; the
-- build must still succeed. Ported from scripts/test-sidecar-ignores-rustc-wrapper.sh
-- (2099-f982), which no gate ran.
--
-- Usage: tillandsias-plan script run scripts/lua/test-sidecar-ignores-rustc-wrapper.lua

local BUILD = "scripts/build-forge-plan-bin.sh"
if not fs.exists(BUILD) then
    verdict.emit("violation:sidecar-ignores-rustc-wrapper:no-subject", 1, BUILD .. " does not exist")
end

local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" } }).stdout or "")
local tgt = env.get("CARGO_TARGET_DIR")
if not tgt or tgt == "" then tgt = ROOT .. "/target" end

local REL = "target/plan-scratch/sidecar-wrapper-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)
local WRAP = ROOT .. "/" .. REL .. "/bad-wrapper"
fs.write(WRAP, "#!/bin/sh\necho \"fake wrapper invoked\" >&2\nexit 254\n")
proc.run({ argv = { "chmod", "+x", WRAP } })
local MT = tgt .. "/sidecar-wrapper-musl"

local r = proc.run({
    argv = { "bash", ROOT .. "/" .. BUILD },
    env = { RUSTC_WRAPPER = WRAP, TILLANDSIAS_SIDECAR_TARGET_DIR = MT, TILLANDSIAS_SIDECAR_FORCE_REBUILD = "1" },
    timeout_ms = 900000,
})
proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL, MT } })

if r.status == "exited" and r.code == 0 then
    verdict.ok("sidecar-ignores-rustc-wrapper", "forge-plan-bin-built")
end
local tail = {}
local lines = text.lines((r.stdout or "") .. (r.stderr or ""))
for i = math.max(1, #lines - 4), #lines do tail[#tail + 1] = lines[i] end
verdict.emit("violation:sidecar-ignores-rustc-wrapper:built-under-wrapper", 1,
    "forge-plan-bin build failed under a failing RUSTC_WRAPPER (" .. tostring(r.code) .. "): " .. table.concat(tail, " | "))
