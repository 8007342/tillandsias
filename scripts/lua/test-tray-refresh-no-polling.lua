-- @trace order:147, order:1533-ew3n, spec:podman-idiomatic-patterns, order:2361-y7pf
--
-- test-tray-refresh-no-polling.lua — scripts/lua/check-tray-refresh-no-polling.lua judges Windows-only
-- source no other host compiles, so every arm mutates a copy of the real file. Arms 5-7: a mention in a
-- comment or a string is not an action, and the accessor's spelling is not the property. Ported from
-- the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/test-tray-refresh-no-polling.lua
-- Verdict: ok:tray-refresh-no-polling-fixture:<n> arms | violation:...:<n>-failed | skip:...:source-absent

local fixture = require "common.fixture"
local T = fixture.new("tray-refresh-no-polling-fixture")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
local CHECK = "scripts/lua/check-tray-refresh-no-polling.lua"
local SRC = "crates/tillandsias-windows-tray/src/notify_icon.rs"
if not fs.exists(SRC) then T:skip("source-absent") end
if PLAN == "" then T:refuse("no-plan-binary") end
local W = T:scratch()
local src = fs.read(SRC):gsub("\r\n", "\n")

local function check(body, script)
    fs.write(W.rel .. "/m.rs", body)
    local r = T:run{ PLAN, "script", "run", script or CHECK, cwd = ROOT, env_unset = { "TILLANDSIAS_*" },
        env = { TILLANDSIAS_TRAY_REFRESH_SOURCE = W.abs .. "/m.rs" } }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
-- A refusal must be the checker's verdict: a crash or an unreadable file is not one.
local function passes(name, body, script)
    local rc, o = check(body, script)
    T:arm(name, rc == 0 and text.contains(o, "ok:tray-refresh-no-polling:5 checked"), o)
end
local function refused(name, body, why)
    local rc, o = check(body)
    T:arm(name, rc == 1 and text.contains(o, "violation:tray-refresh-polling:1") and text.contains(o, why), o)
    return o
end
-- A replacement that does not land would leave an arm judging the real file.
local function swap(s, from, to)
    local a, b = s:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", from) end
    return s:sub(1, a - 1) .. to .. s:sub(b + 1)
end
local VM, GH = "\nasync fn refresh_vm_status(hwnd: HwndHandle) {\n", "\nasync fn refresh_github_login(hwnd: HwndHandle) {\n"
local function into(s, fn, line) return swap(s, fn, fn .. "    " .. line .. "\n") end
local LOOP, VM_WHY = "loop { break; }", "refresh_vm_status contains a loop or a sleep"

passes("0 the real source passes", src)
refused("1 losing the persistent static is caught", swap(src, "\nstatic LIVE_CLIENT", "\nstatic LIVE_CLIENT_RENAMED"),
    "no longer a static")
refused("2 an accessor not backed by the static is caught", swap(src,
    "    LIVE_CLIENT.get_or_init(|| tokio::sync::Mutex::new(None))",
    "    Box::leak(Box::new(tokio::sync::Mutex::new(None)))"), "no longer returns the LIVE_CLIENT static")
local looped = into(src, VM, LOOP)
refused("3 a retry loop in refresh_vm_status is caught", looped, VM_WHY)
refused("4 a sleep in refresh_github_login is caught",
    into(src, GH, "tokio::time::sleep(std::time::Duration::from_secs(1)).await;"),
    "refresh_github_login contains a loop or a sleep")
local commented = into(src, VM, "// this used to loop and sleep( before order 147")
passes("5 a COMMENT naming a loop and a sleep passes", commented)
passes("6 a commented fake function cannot hide the real body",
    "// async fn refresh_vm_status() { loop { break; } }\n" .. src)
local spoofed = "/* outer /* async fn refresh_vm_status() { loop { break; } } */ */\n"
    .. 'const SPOOF: &str = r#"async fn refresh_vm_status() { loop { break; } }"#;\n' .. src
passes("7 nested comments and raw-string braces do not move the body", spoofed)
refused("8 a real loop after the spoofs is caught", into(spoofed, VM, LOOP), VM_WHY)
local o = refused("9 a CRLF source is caught", looped:gsub("\n", "\r\n"), VM_WHY)
T:arm("9 and its diagnostic keeps the matched line's CR", text.contains(o, LOOP .. "\r"), o)

-- MUTATION: a checker that scans the unmasked body refuses a comment (arm 5 is what notices).
local check_src = fs.read(CHECK):gsub("\r\n", "\n")
fs.write(W.rel .. "/unmasked.lua", swap(check_src, "local code = mask_rust(source)", "local code = source"))
local rc, mo = check(commented, W.abs .. "/unmasked.lua")
T:arm("10 MUTATION a checker that does not mask comments refuses arm 5's source",
    rc == 1 and text.contains(mo, VM_WHY), mo)

T:finish()
