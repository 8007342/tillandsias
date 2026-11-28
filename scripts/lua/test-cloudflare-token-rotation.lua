-- @env PATH HOME CARGO_TARGET_DIR
-- @trace order:1505-iysn, order:2382-ubmc
--
-- test-cloudflare-token-rotation.lua — the Cloudflare token rotates once, refresh half first, never
-- in a forge, and every process that should schedules it. Ported from the .sh of the same name
-- (2382-ubmc). Unit tests against tillandsias-fake-cloudflare on loopback, the policy audit on mutated
-- copies, and three call sites read from the source, each with a mutation.
--
-- Usage: tillandsias-plan script run scripts/lua/test-cloudflare-token-rotation.lua
-- Verdict: ok:cloudflare-token-rotation:<n> arms | violation:... | skip:...:no-cargo, no-linker

local fixture = require "common.fixture"
local T = fixture.new("cloudflare-token-rotation")
local C = require("common.cargotest").new(T)
local ROOT = fixture.repo_root()
local MAIN, TRAY, CALL = "crates/tillandsias-headless/src/main.rs", "crates/tillandsias-headless/src/tray/mod.rs", "spawn_cloudflare_token_rotation_scheduler"
local M = "vault_bootstrap::cloudflare_token_rotation_tests::cloudflare_token_rotation_"
local fake = C:build("tillandsias-headless", "tillandsias-fake-cloudflare")
local BASE = { "-p", "tillandsias-headless", "--features", "tray,listen-vsock", "--bins" }
local function run(filter, include, e)
    local a = {}
    for _, v in ipairs(BASE) do a[#a + 1] = v end
    a[#a + 1] = filter
    if include then a[#a + 1] = "--"; a[#a + 1] = "--include-ignored" end
    return C:test(a, e)
end
local x = run("cloudflare_token_rotation_", true, { TILLANDSIAS_FAKE_CLOUDFLARE_BIN = fake })
for _, a in ipairs{ "fake_due_token_rotates_once_refresh_first", "fake_concurrent_checks_exchange_once", "fake_not_due_makes_no_exchange", "fake_refused_refresh_keeps_both_records", "fake_forge_never_rotates",
    "fake_crash_between_writes_loses_nothing", "never_prints_a_token", "records_keep_refresh_off_the_token_path", "refresh_write_failure_keeps_old_pair", "token_endpoint_must_be_https", "scheduler_once_and_backoff_bounded", "policies_keep_forges_out" } do
    T:arm(a, x:ok(M .. a), x:tail())
end
T:arm("cargo test passed", x.rc == 0, x:tail())

-- The audit must catch a policy that opens the records, and name it.
for _, c in ipairs{ { "forge-glob", "forge.hcl", 'path "secret/+/cloudflare/*" { capabilities = ["read"] }', "forge.hcl grants" }, { "forge-wide", "forge.hcl", 'path "secret/*" { capabilities = ["read"] }', "forge.hcl grants" },
    { "mirror-changed", "git-mirror.hcl", 'path "secret/data/ca/proxy-cert" { capabilities = ["read"] }', "git-mirror.hcl grants changed" } } do
    local d, n = T:scratch(), 0
    for _, f in ipairs(fs.list("images/vault/policies")) do
        if f:match("%.hcl$") then fs.write(d.rel .. "/" .. f, fs.read("images/vault/policies/" .. f) .. (f == c[2] and "\n" .. c[3] .. "\n" or "")); n = n + 1 end
    end
    local y = run("cloudflare_token_rotation_policies_keep_forges_out", false, { TILLANDSIAS_TEST_POLICY_AUDIT_DIR = d.abs })
    T:arm("POLICY CONTROL " .. c[1] .. " is caught and named", n > 1 and y:failed(M .. "policies_keep_forges_out") and text.contains(y.out, c[4]), y:tail())
end

-- The body of `fn <name>`, by brace depth outside strings and line comments.
local function body(src, name)
    local l, on, depth, seen = {}, false, 0, 0
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        if not on and (line:find("fn " .. name .. "(", 1, true) or line:find("fn " .. name .. "<", 1, true)) then on = true end
        if on then
            l[#l + 1] = line
            local code = line:gsub('"[^"\\]*"', ""):gsub('"([^"\\]*\\.)*[^"\\]*"', ""):gsub("//.*$", "")
            local o, c = select(2, code:gsub("{", "")), select(2, code:gsub("}", ""))
            depth, seen = depth + o - c, seen + o
            if seen > 0 and depth <= 0 then break end
        end
    end
    return l
end
local function calls(src, name)
    for _, line in ipairs(body(src, name)) do
        if not line:match("^%s*//") and line:find(CALL, 1, true) then return true end
    end
    return false
end
local main, tray = fs.read(MAIN):gsub("\r", ""), fs.read(TRAY):gsub("\r", "")
local fn, tray_fn
for line in (tray .. "\n"):gmatch("([^\n]*)\n") do
    fn = line:match("^%s*pub%([a-z]+%) async fn ([a-z_]+)") or line:match("^%s*pub%([a-z]+%) fn ([a-z_]+)") or line:match("^%s*pub async fn ([a-z_]+)") or line:match("^%s*pub fn ([a-z_]+)") or line:match("^%s*async fn ([a-z_]+)") or line:match("^%s*fn ([a-z_]+)") or fn
    if not line:match("^%s*//") and line:find(CALL, 1, true) then tray_fn = fn; break end
end
T:arm("TRAY the call is in the start-up function that starts the control socket", tray_fn ~= nil and text.contains(table.concat(body(tray, tray_fn or "?"), "\n"), "start_control_socket_server("), tostring(tray_fn))
for _, e in ipairs{ { "TRAY", tray, tray_fn or "none" }, { "LANE", main, "ensure_enclave_for_project" }, { "GUEST", main, "maybe_spawn_vsock_listener" } } do
    T:arm(e[1] .. " " .. e[3] .. " calls " .. CALL, calls(e[2], e[3]), "it would never rotate the token")
    local l, on, done = {}, false, false
    for line in (e[2] .. "\n"):gmatch("([^\n]*)\n") do
        if not on and (line:find("fn " .. e[3] .. "(", 1, true) or line:find("fn " .. e[3] .. "<", 1, true)) then on = true end
        if on and not done and line:find(CALL, 1, true) and not line:match("^%s*//") then line, done = line:gsub("^(%s*)", "%1// ", 1), true end
        l[#l + 1] = line
    end
    T:arm(e[1] .. " MUTATION commenting the call out is caught", done and not calls(table.concat(l, "\n"), e[3]), tostring(done))
end
T:finish()
