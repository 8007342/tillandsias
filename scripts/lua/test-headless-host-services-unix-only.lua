-- @env PATH HOME RUSTUP_HOME CARGO_HOME RUSTUP_TOOLCHAIN
-- @trace order:2289-umyb
--
-- test-headless-host-services-unix-only.lua — host-services builds only for a
-- unix target, and says so in one error. On native Windows it printed 26, all
-- unresolved std::os::unix and nix paths. No Linux gate builds for Windows, so
-- the subject here is the real build.rs: compiled with rustc, then run under the
-- environment cargo gives it for each target.
--
--   arm1  host-services, CARGO_CFG_UNIX absent: exactly one cargo::error line,
--         naming the feature, unix-only and the target
--   arm2  host-services, CARGO_CFG_UNIX present (cargo sets it EMPTY): no error
--   arm3  default features, CARGO_CFG_UNIX absent: no error
--   arm4  NEGATIVE CONTROL: with the target test removed, arm2 refuses
--   arm5  NEGATIVE CONTROL: with the feature test removed, arm3 refuses
--
-- Usage: tillandsias-plan script run scripts/lua/test-headless-host-services-unix-only.lua
-- Verdict: ok:headless-host-services-unix-only:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("headless-host-services-unix-only")
local ROOT = fixture.repo_root()
local CRATE = ROOT .. "/crates/tillandsias-headless"
local TARGET = "x86_64-pc-windows-msvc"

local W = T:scratch()

local function compile(src, name)
    T:must{ "rustc", "--edition", "2024", "-A", "warnings", src, "-o", W.abs .. "/" .. name .. ".exe" }
    return W.abs .. "/" .. name .. ".exe"
end

local function ask(bin, env)
    env.CARGO_MANIFEST_DIR = CRATE
    env.TARGET = TARGET
    local r = T:run{ bin, env = env }
    local _, errors = ("\n" .. tostring(r.stdout)):gsub("\ncargo::error=", "")
    -- A clean run reached the end: the probe fingerprint is the last line it prints.
    local fp = tostring(r.stdout):find("TILLANDSIAS_PROBE_REVISION=%x+") ~= nil
    local got = "code=" .. tostring(r.code) .. " errors=" .. errors .. " out=" .. tostring(r.stdout) .. tostring(r.stderr)
    return { refused = r.code == 0 and errors == 1 and not fp,
             clean = r.code == 0 and errors == 0 and fp, out = tostring(r.stdout), got = got }
end

local function win_hs()  return { CARGO_FEATURE_HOST_SERVICES = "1" } end
local function unix_hs() return { CARGO_FEATURE_HOST_SERVICES = "1", CARGO_CFG_UNIX = "" } end
local function win_default() return {} end

local real = compile(CRATE .. "/build.rs", "real")
local a = ask(real, win_hs())
T:arm("arm1 host-services for a non-unix target is one error naming it",
    a.refused and a.out:find("host-services is unix-only", 1, true) and a.out:find(TARGET, 1, true), a.got)
a = ask(real, unix_hs())
T:arm("arm2 host-services for a unix target is not refused", a.clean, a.got)
a = ask(real, win_default())
T:arm("arm3 default features for a non-unix target are not refused", a.clean, a.got)

-- Each mutant must land: exactly one occurrence, replaced.
local src = fs.read("crates/tillandsias-headless/build.rs")
local function mutant(name, find, put)
    local _, n = src:gsub(find:gsub("%p", "%%%0"), "")
    if n ~= 1 then T:refuse("mutant-did-not-apply", name .. ": " .. n .. " occurrences") end
    local i, j = src:find(find, 1, true)
    fs.write(W.rel .. "/" .. name .. ".rs", src:sub(1, i - 1) .. put .. src:sub(j + 1))
    return compile(W.abs .. "/" .. name .. ".rs", name)
end

a = ask(mutant("no_target_test", 'std::env::var_os("CARGO_CFG_UNIX").is_none()', "true"), unix_hs())
T:arm("arm4 control: without the target test, the unix build is refused", a.refused, a.got)
a = ask(mutant("no_feature_test", 'std::env::var_os("CARGO_FEATURE_HOST_SERVICES").is_some()', "true"), win_default())
T:arm("arm5 control: without the feature test, the default build is refused", a.refused, a.got)

T:finish{ ok = function(n) return "ok:headless-host-services-unix-only:" .. n .. " arms" end }
