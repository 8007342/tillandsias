-- @trace spec:default-image, spec:forge-as-only-runtime, order:2167-wshb
-- @env PATH HOME CARGO_HOME RUSTUP_HOME RUSTUP_TOOLCHAIN TILLANDSIAS_POLICY_TARGET_PARENT TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-forge-policy-binary-discoverability.lua — the policy wrappers resolve
-- their binaries from a CARGO_TARGET_DIR redirected OUTSIDE the repo root.
-- Ported from the .sh of the same name (order 2167-wshb); same four steps.
--
-- The redirected target dir lives under the forge's cache by default;
-- TILLANDSIAS_POLICY_TARGET_PARENT moves it, so a host can run the same steps
-- (1630-dwab measured them on darwin that way). It is outside the checkout, so
-- it is made and removed with mktemp/find through proc.run, never fs.*.
--
-- Steps (each must exit 0, except the podman probe, which only must not hang):
--   1  cargo build -p tillandsias-policy into the redirected dir
--   2  scripts/lua/check-no-python-scripts.lua on the one runner, redirected
--   3  scripts/tillandsias-policy validate-yaml methodology.yaml, redirected
--   4  scripts/tillandsias-podman --version, redirected (discovery only)
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-policy-binary-discoverability.lua
-- Verdict: ok:forge-policy-binary-discoverability:4/4

local NAME = "forge-policy-binary-discoverability"
local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }).stdout or "")
if ROOT == "" then verdict.could_not_run(NAME, "not inside a git checkout") end

local base = {}
for _, k in ipairs({ "PATH", "HOME", "CARGO_HOME", "RUSTUP_HOME", "RUSTUP_TOOLCHAIN" }) do base[k] = env.get(k) end
local function run(argv, extra, timeout)
    local e = {}
    for k, v in pairs(base) do e[k] = v end
    for k, v in pairs(extra or {}) do e[k] = v end
    return proc.run({ argv = argv, cwd = ROOT, env = e, timeout_ms = timeout or 120000 })
end

local parent = env.get("TILLANDSIAS_POLICY_TARGET_PARENT")
if parent == nil or parent == "" then parent = "/home/forge/.cache" end
local mk = run({ "mktemp", "-d", parent .. "/test-policy-target.XXXXXX" })
local T = text.trim(mk.stdout or "")
if mk.code ~= 0 or T == "" then
    verdict.could_not_run(NAME, "cannot make a target dir under " .. parent .. " (set TILLANDSIAS_POLICY_TARGET_PARENT on a host)")
end
local RT = { CARGO_TARGET_DIR = T }

local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if PLAN == nil or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if PLAN == nil or PLAN == "" then PLAN = "tillandsias-plan" end

local pass, fail = 0, 0
local function step(name, r, must_pass)
    local ok = r.status == "exited" and (r.code == 0 or not must_pass)
    if ok then pass = pass + 1; out.line("ok:   " .. name)
    else
        fail = fail + 1
        out.line("FAIL: " .. name .. " — status=" .. tostring(r.status) .. " rc=" .. tostring(r.code))
        local tail = text.lines(r.stderr or "")
        for i = math.max(1, #tail - 4), #tail do if tail[i] then log.raw("    " .. tail[i]) end end
    end
    return ok
end

log.raw("Building tillandsias-policy into CARGO_TARGET_DIR=" .. T .. "...")
if step("1 tillandsias-policy builds into the redirected target dir",
        run({ "cargo", "build", "--quiet", "--manifest-path", ROOT .. "/Cargo.toml", "-p", "tillandsias-policy" }, RT, 1800000), true) then
    step("2 check-no-python-scripts.lua runs with the redirected target dir",
        run({ PLAN, "script", "run", "scripts/lua/check-no-python-scripts.lua" }, RT), true)
    step("3 tillandsias-policy validate-yaml finds the redirected binary",
        run({ ROOT .. "/scripts/tillandsias-policy", "validate-yaml", ROOT .. "/methodology.yaml" }, RT), true)
    step("4 tillandsias-podman discovery returns under the redirected target dir",
        run({ ROOT .. "/scripts/tillandsias-podman", "--version" }, RT), false)
end

run({ "find", T, "-delete" })
if fail > 0 then verdict.emit("violation:" .. NAME .. ":" .. pass .. "/" .. (pass + fail), 1) end
verdict.ok(NAME, pass .. "/4")
