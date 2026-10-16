-- @trace order:1713-3v3f
-- @env PATH TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-no-host-browser-launch.lua — the guard of 1713-3v3f,
-- scripts/lua/check-no-host-browser-launch.lua, on this tree and on
-- constructed roots:
--   1 LIVE      this tree: every launcher-shaped site is allowlisted at its count
--   2 PLANT     a planted second launch site (ShellExecuteW with a URL) is
--               refused, naming the file and the line (NEGATIVE CONTROL)
--   3 COUNT     a second "/usr/bin/open" in an allowlisted file is a
--               count-mismatch: the allowlist pins cardinality, not presence
--   4 BLIND     a launch in a // comment, after #[cfg(test)], or under tests/
--               is not a site, but a // inside a string (https://) does not
--               hide a launch later on the same line
--   5 CONTEXT   "open" as a Lua table key is not a site; "open" alone on a
--               line (a program chosen into a variable) and cmd /c "start" are
--   6 ABSENT    a root with no .rs files is could-not-run, exit 3
--
-- Usage: tillandsias-plan script run scripts/lua/test-no-host-browser-launch.lua

local SUBJECT_REL = "scripts/lua/check-no-host-browser-launch.lua"
if not fs.exists(SUBJECT_REL) then
    verdict.emit("violation:no-host-browser-launch-fixture:no-subject", 1, SUBJECT_REL .. " does not exist (1713-3v3f)")
end
local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("no-host-browser-launch-fixture", "no plan binary named (TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("no-host-browser-launch-fixture", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/no-host-browser-launch-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)

local failed = {}
local function arm(name, cond, got)
    -- The subject's output stays on this arm's ONE line: its own `violation:`
    -- line at the start of a line would read as this fixture's verdict.
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local function run(roots)
    local e = {}
    if roots then e.TILLANDSIAS_HOST_BROWSER_SCAN_ROOTS = roots end
    local r = proc.run({ argv = { PLAN, "script", "run", SUBJECT_REL }, cwd = ROOT, timeout_ms = 60000, env = e })
    return r.code or -1, text.trim(r.stdout or "")
end
-- root(name, { [rel] = body, ... }) -> the root's repo-relative path
local function root(name, files)
    local d = REL .. "/" .. name
    for rel, body in pairs(files) do
        local dir = (d .. "/" .. rel):match("^(.*)/[^/]+$")
        fs.mkdir(dir)
        fs.write(d .. "/" .. rel, body)
    end
    return d
end
-- The three allowlisted non-URL sites, each once: a clean baseline.
local BASE = {
    ["tillandsias-windows-tray/src/notify_icon.rs"] =
        'fn open_log_file() {\n    let _ = std::process::Command::new("explorer.exe")\n        .arg(x);\n}\n',
    ["tillandsias-macos-tray/src/action_host.rs"] =
        'fn log() {\n    let mut command = std::process::Command::new("/usr/bin/open");\n}\n',
    ["tillandsias-macos-tray/src/terminal_attach.rs"] =
        'fn warp() {\n    std::process::Command::new("/usr/bin/open").arg("-a").arg("Warp");\n}\n',
}
local function with(extra)
    local t = {}
    for k, v in pairs(BASE) do t[k] = v end
    for k, v in pairs(extra) do t[k] = v end
    return t
end

-- ── 1 LIVE ─────────────────────────────────────────────────────────────────
local rc, o = run(nil)
arm("1 LIVE this tree has no host-browser launch outside the allowlist",
    rc == 0 and o:find("^ok:no%-host%-browser%-launch:files=%d+:sites=3:allowed=3$") ~= nil, rc .. " " .. o)

-- ── 2 PLANT ────────────────────────────────────────────────────────────────
local d = root("plant", with({ ["tillandsias-windows-tray/src/links.rs"] =
    'fn hand_off(url: &str) {\n    unsafe { ShellExecuteW(None, w!("open"), &url, None, None, SW_SHOW) };\n}\n' }))
local base_rc, base_o = run(root("base", BASE))
rc, o = run(d)
arm("2 PLANT a planted ShellExecuteW is refused naming the file and line; the same root without it passes",
    base_rc == 0 and base_o:find("sites=3:allowed=3", 1, true) ~= nil
    and rc == 1 and o:find("violation:no-host-browser-launch:unlisted=1:count-mismatch=0", 1, true) ~= nil
    and o:find("unlisted: " .. d .. "/tillandsias-windows-tray/src/links.rs:2:", 1, true) ~= nil
    and o:find("remedy:", 1, true) ~= nil,
    base_rc .. " " .. base_o .. " / " .. rc .. " " .. o)

-- ── 3 COUNT ────────────────────────────────────────────────────────────────
rc, o = run(root("count", with({ ["tillandsias-macos-tray/src/action_host.rs"] =
    'fn log() {\n    let a = std::process::Command::new("/usr/bin/open");\n}\nfn url(u: &str) {\n    std::process::Command::new("/usr/bin/open").arg(u);\n}\n' })))
arm("3 COUNT a second /usr/bin/open in an allowlisted file is a count-mismatch",
    rc == 1 and o:find("violation:no-host-browser-launch:unlisted=0:count-mismatch=1", 1, true) ~= nil
    and o:find("expected 1 got 2", 1, true) ~= nil, rc .. " " .. o)

-- ── 4 BLIND ────────────────────────────────────────────────────────────────
rc, o = run(root("blind", with({
    ["tillandsias-headless/src/a.rs"] = 'fn a() {}\n// a ShellExecuteW here would open "xdg-open"\n#[cfg(test)]\nmod tests {\n    fn t() { open::that("https://x"); }\n}\n',
    ["tillandsias-headless/tests/b.rs"] = 'fn b() { webbrowser::open("https://x"); }\n',
})))
local blind_rc, blind_o = rc, o
rc, o = run(root("url-string", with({
    ["tillandsias-headless/src/c.rs"] = 'fn c() { let u = "https://example.com"; open::that(u); }\n' })))
arm("4 BLIND comments, #[cfg(test)] tails and tests/ are skipped; a // inside a string hides nothing",
    blind_rc == 0 and blind_o:find("sites=3:allowed=3", 1, true) ~= nil
    and rc == 1 and o:find("unlisted=1", 1, true) ~= nil and o:find("/src/c.rs:1:", 1, true) ~= nil,
    blind_rc .. " " .. blind_o .. " / " .. rc .. " " .. o)

-- ── 5 CONTEXT ──────────────────────────────────────────────────────────────
rc, o = run(root("ctx-no", with({
    ["tillandsias-plan/src/l.rs"] = 'fn l() {\n    let _ = io_table.set("open", LuaValue::Nil);\n    client.execute(&["start".into(), name.into()]);\n}\n' })))
local no_rc, no_o = rc, o
rc, o = run(root("ctx-yes", with({
    ["tillandsias-headless/src/o.rs"] = 'fn opener() -> &str {\n    if mac {\n        "open"\n    } else {\n        "x"\n    }\n}\nfn win(u: &str) {\n    Command::new("cmd").args(["/c", "start", u]);\n}\n' })))
arm("5 CONTEXT a Lua key and podman start are not sites; a bare \"open\" arm and cmd /c start are",
    no_rc == 0 and rc == 1 and o:find("unlisted=2", 1, true) ~= nil
    and o:find("/src/o.rs:3:", 1, true) ~= nil and o:find("/src/o.rs:9:", 1, true) ~= nil,
    no_rc .. " " .. no_o .. " / " .. rc .. " " .. o)

-- ── 6 ABSENT ───────────────────────────────────────────────────────────────
fs.mkdir(REL .. "/empty/x")
rc, o = run(REL .. "/empty")
arm("6 ABSENT a root with no .rs files is could-not-run, exit 3",
    rc == 3 and o:find("could-not-run:no-host-browser-launch", 1, true) ~= nil, rc .. " " .. o)

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("refused:no-host-browser-launch-fixture:" .. #failed .. "-of-6", 1)
end
verdict.emit("ok:no-host-browser-launch-fixture:6", 0)
