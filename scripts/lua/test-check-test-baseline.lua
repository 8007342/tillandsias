-- @env PATH HOME
-- @trace spec:ci-release, order:2366-7zvv
--
-- test-check-test-baseline.lua — check-test-baseline.sh reads a cargo-test transcript against a
-- list of known-red tests. Ported from the .sh of the same name (2366-7zvv). No cargo runs.
--
--   1 the listed failure alone is tolerated      2 an unlisted one is new-red
--   3 a listed test that passes is stale         4 both together: the new red first
--   5 a listed test not in the transcript, and 6 one that is ignored, are neither
--   7 the same name in another binary is not covered
--   8 no test results refuses                    9 the per-binary summary is not a test
--   10 a missing list refuses, never an empty one
--
-- Usage: tillandsias-plan script run scripts/lua/test-check-test-baseline.lua
-- Verdict: ok:check-test-baseline:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("check-test-baseline")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local d = T:scratch()
local PROXY, BUMPED, BUMP_HOST = "proxy_cache_policy::", "bumped_origin_tls_and_signed_url_logs_fail_closed", "ssl_bump_is_step_scoped_to_one_exact_release_asset_host"
local STAYS = "a_real_packet_stays_answerable"
local PLAN_BIN = "     Running unittests src/lib.rs (target/debug/deps/tillandsias_plan-9459f657098fa92c)\n\n"
local PROXY_BIN = "     Running tests/proxy_cache_policy.rs (target/debug/deps/proxy_cache_policy-16b4029ff16a4a4c)\n\n"
local function full(stays, bumped)
    return "   Compiling tillandsias-plan v0.1.0 (/repo/crates/tillandsias-plan)\n    Finished `test` profile [unoptimized + debuginfo] target(s) in 1.25s\n" .. PLAN_BIN
        .. "running 2 tests\ntest answer::tests::epoch_formatting_is_correct ... ok\ntest answer::tests::" .. STAYS .. " ... " .. stays
        .. "\n\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.10s\n\n" .. PROXY_BIN .. "running 2 tests\ntest " .. BUMP_HOST .. " ... ok\ntest " .. BUMPED .. " ... " .. bumped
        .. "\n\ntest result: FAILED. 1 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s\n"
end
local function one(bin, name, result) return bin .. "running 1 test\ntest " .. name .. " ... " .. result .. "\n\ntest result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s\n" end
local SEEDED, OTHER = "\n" .. PROXY .. BUMPED .. "\n", PROXY .. BUMP_HOST .. "\n"
-- list: its text, or false for a list that is not there
local function arm(name, rc, prefix, transcript, list)
    fs.write(d.rel .. "/t.txt", transcript)
    if list then fs.write(d.rel .. "/list.txt", list) end
    local r = proc.run{ argv = { SH, ROOT .. "/scripts/check-test-baseline.sh", "--from", d.abs .. "/t.txt", "--list", d.abs .. (list and "/list.txt" or "/gone.txt") }, cwd = ROOT,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME") }, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local o = r.stdout or ""
    T:arm(name, r.code == rc and o:sub(1, #prefix) == prefix, "rc=" .. tostring(r.code) .. " " .. o .. (r.stderr or ""):sub(1, 300))
end
local V = ":test-baseline:"
arm("1 the listed failure alone is tolerated", 0, "ok" .. V .. "ran=4 new-red=0 tolerated=1 stale=0", full("ok", "FAILED"), SEEDED)
arm("2 an unlisted failure is a new regression, by name", 1, "fail" .. V .. "ran=4 new-red=1 tolerated=1 stale=0 first=tillandsias_plan::answer::tests::" .. STAYS, full("FAILED", "FAILED"), SEEDED)
arm("3 a listed test that now passes is stale, by name", 1, "fail" .. V .. "ran=4 new-red=0 tolerated=0 stale=1 first=" .. PROXY .. BUMPED, full("ok", "ok"), SEEDED)
arm("4 a new red and a stale entry: the new red first", 1, "fail" .. V .. "ran=4 new-red=2 tolerated=0 stale=1 first=" .. PROXY .. BUMPED, full("FAILED", "FAILED"), OTHER)
arm("5 a listed test not in the transcript is neither", 0, "ok" .. V .. "ran=1 new-red=0 tolerated=0 stale=0", one(PLAN_BIN, "answer::tests::epoch_formatting_is_correct", "ok"), SEEDED)
arm("6 a listed test that is ignored is neither", 0, "ok" .. V .. "ran=1 new-red=0 tolerated=0 stale=0", one(PROXY_BIN, BUMPED, "ignored, needs squid"), SEEDED)
arm("7 the same name in another binary is not covered", 1, "fail" .. V .. "ran=1 new-red=1 tolerated=0 stale=0 first=other_suite::" .. BUMPED,
    one("     Running tests/other_suite.rs (target/debug/deps/other_suite-deadbeefdeadbeef)\n\n", BUMPED, "FAILED"), SEEDED)
arm("8 a transcript with no test results refuses", 2, "fail" .. V .. "no-test-results=", "   Compiling tillandsias-plan v0.1.0\nerror[E0425]: cannot find value `nope` in this scope\nerror: could not compile `tillandsias-plan` (lib test)\n", SEEDED)
arm("9 the per-binary summary is not counted as a test", 0, "ok" .. V .. "ran=4 ", full("ok", "FAILED"), SEEDED)
arm("10 a missing list refuses rather than reading as empty", 2, "fail" .. V .. "missing-known-red=", full("ok", "FAILED"), false)
T:finish()
