-- @trace order:846-idhn, order:746-htj9, order:2183-mfbn
-- inputs: .cargo/config.toml Cargo.lock Cargo.toml crates/tillandsias-browser-mcp/Cargo.toml crates/tillandsias-control-wire/Cargo.toml crates/tillandsias-core/Cargo.toml crates/tillandsias-embed/Cargo.toml crates/tillandsias-enclave-fetch/Cargo.toml crates/tillandsias-exec/Cargo.toml crates/tillandsias-fleet-core/Cargo.toml crates/tillandsias-headless/Cargo.toml crates/tillandsias-host-shell/Cargo.toml crates/tillandsias-litmus-rust/Cargo.toml crates/tillandsias-logging/Cargo.toml crates/tillandsias-macos-tray/Cargo.toml crates/tillandsias-metrics/Cargo.toml crates/tillandsias-msg/Cargo.toml crates/tillandsias-otp/Cargo.toml crates/tillandsias-podman/Cargo.toml crates/tillandsias-podman-cli/Cargo.toml crates/tillandsias-policy/Cargo.toml crates/tillandsias-policy/src/main.rs crates/tillandsias-progress-tty/Cargo.toml crates/tillandsias-repeat-graph/Cargo.toml crates/tillandsias-router-sidecar/Cargo.toml crates/tillandsias-scanner/Cargo.toml crates/tillandsias-secure-channel/Cargo.toml crates/tillandsias-static-server/Cargo.toml crates/tillandsias-vault-client/Cargo.toml crates/tillandsias-vm-layer/Cargo.toml crates/tillandsias-windows-tray/Cargo.toml images/default/lib-common.sh README.md rust-toolchain.toml scripts/check-plan-binary-current.sh scripts/check-resumable-claim-dirt.sh scripts/check-stranded-in-progress.sh scripts/cycle-preflight.sh scripts/lua/check-all-fragments-intact.lua scripts/lua/test-plan-binary-probe-release-over-debug.lua scripts/plan-binary-probe.sh scripts/regenerate-cheatsheet-index.sh scripts/select-work-batch.sh scripts/tillandsias-policy scripts/with-wsl2-builder.sh scripts/wsl-plan-expert-ensure.sh VERSION lib/lua/common/ crates/tillandsias-plan/
-- @env PATH HOME TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-all-fragments-intact.lua — negative controls for
-- scripts/lua/check-all-fragments-intact.lua. Runs against a scratch fixture
-- root under target/ and never touches plan/. Ported from the .sh of the same
-- name (order 2183-mfbn); same three arms, same verdicts.
--
-- Usage: tillandsias-plan script run scripts/lua/test-all-fragments-intact.lua
-- Verdicts:
--   ok:all-fragments-intact-fixture:3/3                              exit 0
--   skip:all-fragments-intact-fixture:no-script-runner               exit 0
--   violation:all-fragments-intact-fixture:<why>                     exit 1

local NAME = "all-fragments-intact-fixture"
local BASE = { PATH = env.get("PATH"), HOME = env.get("HOME") }
local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, env = BASE }).stdout or "")

-- The runner names itself when the gate calls it; by hand, proc.run denies
-- `sh -c` so plan-binary-probe.sh cannot be sourced: take the PATH binary.
local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if PLAN == nil or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if PLAN == nil or PLAN == "" then
    for dir in (BASE.PATH or ""):gmatch("[^:]+") do
        local c = dir .. "/tillandsias-plan"
        if dir:sub(1, 1) == "/" and proc.run({ argv = { "test", "-x", c }, env = BASE }).code == 0 then PLAN = c; break end
    end
end
local caps = (PLAN and PLAN ~= "") and proc.run({ argv = { PLAN, "capabilities" }, env = BASE }).stdout or ""
local has_script = false
for _, l in ipairs(text.lines(caps)) do if l == "script" then has_script = true end end
if not has_script then
    verdict.emit("skip:" .. NAME .. ":no-script-runner — no tillandsias-plan with `script run` resolves; rebuild it (cargo build --release -p tillandsias-plan)", 0)
end

local SUT = ROOT .. "/scripts/lua/check-all-fragments-intact.lua"
local REL = "target/plan-scratch/all-fragments-intact." .. tostring(time.now_ms())
local W = ROOT .. "/" .. REL
fs.mkdir(REL .. "/plan/index.d")
fs.mkdir(REL .. "/bin")
local function cleanup() proc.run({ argv = { "rm", "-rf", W }, env = BASE }) end
local function fail(why) cleanup(); verdict.emit("violation:" .. NAME .. ":" .. why, 1) end
local function sut(path_prefix)
    local e = { PATH = BASE.PATH, HOME = BASE.HOME, TILLANDSIAS_FRAGMENT_SCAN_ROOT = W }
    if path_prefix then e.PATH = path_prefix .. ":" .. e.PATH end
    local r = proc.run({ argv = { PLAN, "script", "run", SUT }, env = e, timeout_ms = 120000 })
    return text.trim(r.stdout or ""), r.code
end

-- A fake Ruby proves the checker does not trip the forge's on-demand shim.
fs.write(REL .. "/bin/ruby", "#!/bin/sh\n: > \"" .. W .. "/ruby-called\"\nexit 97\n")
proc.run({ argv = { "chmod", "+x", W .. "/bin/ruby" }, env = BASE })

fs.write(REL .. "/plan/index.d/good.yaml", "events:\n  - packet_id: fixture\n    event:\n      type: note\n      summary: valid\n")
local o, rc = sut(W .. "/bin")
if rc ~= 0 then fail("valid fixture refused: " .. o) end
if o ~= "ok:all-fragments-intact:1 checked" then fail("unexpected valid verdict: " .. o) end
if fs.exists(REL .. "/ruby-called") then fail("checker invoked Ruby instead of the repository validator") end
out.line("ok: valid YAML uses the repository validator, not Ruby")

fs.write(REL .. "/plan/index.d/bad.yaml", "events:\n  - packet_id: [\n")
o, rc = sut()
if rc == 0 then fail("unparseable YAML must be refused") end
if o ~= "blocked:all-fragments-intact:1 damaged" then fail("unexpected parse-failure verdict: " .. o) end
proc.run({ argv = { "rm", W .. "/plan/index.d/bad.yaml" }, env = BASE })
out.line("ok: unparseable YAML is refused")

fs.write(REL .. "/plan/index.d/conflict.yaml", "events:\n  - packet_id: fixture\n    event:\n      type: note\n      summary: |\n        <<<<<<< ours\n        valid YAML, damaged ledger content\n        >>>>>>> theirs\n")
o, rc = sut()
if rc == 0 then fail("an indented conflict marker must be refused") end
if o ~= "blocked:all-fragments-intact:1 damaged" then fail("unexpected conflict-marker verdict: " .. o) end
out.line("ok: conflict markers inside valid block scalars are refused")

cleanup()
verdict.ok(NAME, "3/3")
