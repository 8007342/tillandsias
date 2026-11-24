-- @trace spec:git-mirror-service, order:2286-5agy
-- @env CARGO_TARGET_DIR TILLANDSIAS_FORGE_IMAGE TILLANDSIAS_PARITY_ROOT
--
-- test-forge-config-trust-cross-platform-parity.lua — VZ and WSL boot the same
-- Linux headless binary, so git configuration and runtime CA injection stay in
-- the shared in-guest path instead of growing platform-specific overrides.
-- Ported from the .sh, which had two silent holes: its forbid check ran `rg`
-- inside an `if`, so a missing rg read as "nothing found"; and a `cargo test`
-- filter that matches no test passes.
--
--   1 SHARED    each guest launch path carries its marker
--   2 RETIRED   the local-checkout launch form is gone from both trays (776-jcf3)
--   3 OVERRIDE  no host-side surface sets git or trust variables; and a planted
--               one IS found (the control)
--   4 CARGO     the four tests pass, and each filter ran at least one test
--   5 LIVE      the gitconfig and CA fixtures pass
--
-- TILLANDSIAS_PARITY_ROOT names another tree for arms 1-3 (a mutation's seam);
-- arms 4-5 then do not run, and the verdict says so.
--
-- Verdict: ok:forge-config-trust-parity:<n> | violation:…:<n> |
--          skip:forge-config-trust-parity:source-arms-only:<n>

local fixture = require "common.fixture"
local T = fixture.new("forge-config-trust-parity")
local ALT = env.get("TILLANDSIAS_PARITY_ROOT")
local BASE = (ALT and ALT ~= "") and (ALT .. "/") or ""

local missing = {}
for _, m in ipairs({
    { "crates/tillandsias-vm-layer/src/vz.rs", "ExecStart=/usr/local/bin/tillandsias-headless --listen-vsock 42420" },
    { "crates/tillandsias-vm-layer/src/wsl.rs", "ExecStart=/usr/local/bin/tillandsias-headless --listen-vsock {port}" },
    { "crates/tillandsias-windows-tray/src/wsl_lifecycle.rs", "ExecStart=/usr/local/bin/tillandsias-headless --listen-vsock 42420" },
    -- 1928-s9ae: both trays launch a forge in the guest by the CLOUD form.
    { "crates/tillandsias-macos-tray/src/diagnose.rs", "exec /usr/local/bin/tillandsias-headless --cloud {} --opencode" },
    { "crates/tillandsias-host-shell/src/pty/mod.rs", "GUEST_HEADLESS_BIN.to_string()," },
    { "crates/tillandsias-host-shell/src/pty/mod.rs", '"--cloud".to_string(),' },
    { "crates/tillandsias-windows-tray/src/notify_icon.rs", "use tillandsias_host_shell::pty::{PtyIntent, intent_for_action, launch_spec};" },
}) do
    local s = fs.exists(BASE .. m[1]) and fs.read(BASE .. m[1]) or ""
    if not s:find(m[2], 1, true) then missing[#missing + 1] = m[1] .. ": " .. m[2] end
end
T:arm("1 SHARED every guest launch path carries its shared-guest marker", #missing == 0, table.concat(missing, " | "))

-- Every file under a directory, or the file itself. A surface that is gone is
-- named: an empty scan is not a clean one.
local function files_of(surface)
    if fs.exists(BASE .. surface) then
        local ok, l = pcall(fs.walk, BASE .. surface)
        if ok and #l > 0 then return l end
        if surface:find("%.%w+$") then return { BASE .. surface } end
    end
    return nil
end
local function scan(surfaces, hit)
    local found, gone, n = {}, {}, 0
    for _, s in ipairs(surfaces) do
        local l = files_of(s)
        if not l then gone[#gone + 1] = s end
        for _, f in ipairs(l or {}) do
            local path = fs.exists(f) and f or (BASE .. s .. "/" .. f)
            local body = fs.read(path)
            if body then
                n = n + 1
                local w = hit(body)
                if w then found[#found + 1] = path .. ":" .. w end
            end
        end
    end
    return found, gone, n
end

local found, gone, n = scan({ "crates/tillandsias-macos-tray/src", "crates/tillandsias-windows-tray/src", "crates/tillandsias-host-shell/src" },
    function(b) return b:find("tillandsias-headless --opencode {path}", 1, true) and "retired-form" end)
T:arm("2 RETIRED the local-checkout launch form is on neither tray (" .. n .. " files read)",
    #found == 0 and #gone == 0 and n > 0, table.concat(found, " ") .. " gone=" .. table.concat(gone, " "))

local WORDS = { "GIT_CONFIG_GLOBAL", "GIT_SSL_CAINFO", "SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "NODE_EXTRA_CA_CERTS",
    "CURL_CA_BUNDLE", "/home/forge/.gitconfig", "ca-chain.crt" }
local function override(b)
    for _, w in ipairs(WORDS) do if b:find(w, 1, true) then return w end end
end
found, gone, n = scan({ "crates/tillandsias-vm-layer/src", "crates/tillandsias-windows-tray/src", "crates/tillandsias-macos-tray/src",
    "scripts/build-macos-tray.sh", "scripts/build-windows-tray.ps1" }, override)
local blind = {}
for _, w in ipairs(WORDS) do if override("x " .. w .. " y") ~= w then blind[#blind + 1] = w end end
T:arm("3 OVERRIDE no host surface sets git or trust variables (" .. n .. " files read), and each word is one the scan can see",
    #found == 0 and #gone == 0 and n > 0 and #blind == 0, table.concat(found, " ") .. " gone=" .. table.concat(gone, " ") .. " blind=" .. table.concat(blind, " "))

if BASE ~= "" then
    T:finish{ ok = function(k) return "skip:forge-config-trust-parity:source-arms-only:" .. k end }
end

local ctd = env.get("CARGO_TARGET_DIR")
local red = {}
for _, c in ipairs({ { "tillandsias-host-shell", "launch_spec" },
    { "tillandsias-vm-layer", "vz_cloud_init_headless_service_has_control_wire_preflight" },
    { "tillandsias-headless", "forge_credential_quarantine_mounts_present" },
    { "tillandsias-headless", "opencode_args_mount_workspace_and_prompt" } }) do
    local r = T:run{ "cargo", "test", "-q", "-p", c[1], c[2], timeout_ms = 900000, env = { CARGO_TARGET_DIR = ctd } }
    local ran = 0
    for k in (r.stdout or ""):gmatch("test result: %w+%. (%d+) passed") do ran = ran + tonumber(k) end
    if r.code ~= 0 or ran == 0 then
        red[#red + 1] = c[1] .. "/" .. c[2] .. " rc=" .. tostring(r.code) .. " ran=" .. ran .. " " .. (r.stderr or ""):sub(-300)
    end
end
T:arm("4 CARGO the four tests pass, and each filter ran at least one test", #red == 0, table.concat(red, " | "))

local live = {}
for _, s in ipairs({ "scripts/test-forge-standard-gitconfig-path.sh", "scripts/test-forge-runtime-ca-trust.sh" }) do
    local r = T:run{ fixture.posix_shell(), s, timeout_ms = 300000, env = { TILLANDSIAS_FORGE_IMAGE = env.get("TILLANDSIAS_FORGE_IMAGE") } }
    if r.code ~= 0 then live[#live + 1] = s .. " rc=" .. tostring(r.code) .. " " .. ((r.stdout or "") .. (r.stderr or "")):sub(-300) end
end
T:arm("5 LIVE the gitconfig and CA fixtures pass", #live == 0, table.concat(live, " | "))
T:finish()
