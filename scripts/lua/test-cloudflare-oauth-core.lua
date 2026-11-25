-- @env PATH HOME CARGO_TARGET_DIR
-- @trace order:1505-kyx8, order:2382-ubmc
--
-- test-cloudflare-oauth-core.lua — cloudflare_oauth's begin, exchange, refresh and revoke complete a
-- PKCE login over loopback against tillandsias-fake-cloudflare. Ported from the .sh of the same name
-- (2382-ubmc). The five #[ignore]d loopback tests, run by name; no real account, token or network.
--
-- Usage: tillandsias-plan script run scripts/lua/test-cloudflare-oauth-core.lua
-- Verdict: ok:cloudflare-oauth-core:<n> arms | violation:... | skip:...:no-cargo, no-linker

local fixture = require "common.fixture"
local T = fixture.new("cloudflare-oauth-core")
local C = require("common.cargotest").new(T)
local fake = C:build("tillandsias-headless", "tillandsias-fake-cloudflare")
local ARMS = { "loopback_exchange_succeeds_with_right_state_and_verifier", "loopback_state_mismatch_makes_zero_token_requests", "loopback_refresh_rotates_and_invalidates_old_refresh_token",
    "loopback_revoke_succeeds_against_real_fake", "loopback_device_grant_note_printed_when_discovery_lists_it" }
local x = C:test({ "-p", "tillandsias-headless", "--bin", "tillandsias", "cloudflare_oauth::loopback_tests", "--", "--ignored", "--test-threads=1", "--nocapture" }, { TILLANDSIAS_FAKE_CLOUDFLARE_BIN = fake })
for _, a in ipairs(ARMS) do
    -- --nocapture puts a test's own output between its name and its result.
    local at = x.out:find("\ntest cloudflare_oauth::loopback_tests::" .. a .. " ", 1, true)
    local next_ = at and (x.out:find("\ntest ", at + 1, true) or #x.out + 1)
    local span = at and x.out:sub(at, next_ - 1) .. "\n" or ""
    T:arm(a, at ~= nil and not text.contains(span, "FAILED") and span:find("ok[\n ]") ~= nil, x:tail())
end
T:arm("the device-grant note was printed", text.contains(x.out, "note:cloudflare-login:device-grant-available"), x:tail())
T:arm("all five passed and none failed", x.rc == 0 and x.out:find("\ntest result: ok%. " .. #ARMS .. " passed; 0 failed;") ~= nil, x:tail())
T:finish()
