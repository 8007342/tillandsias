-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:1802-9xix
--
-- Fixture for check-opencode-web-window.lua. It copies the four sources into
-- target/ and runs the check through its seam:
--   GREEN: the tree as it is -> ok;
--   RED:   host networking for the window, a plaintext window URL, an
--          unfiltered `next`, and a landing check that accepts //host -> each
--          a violation.

local runner = env.get("TILLANDSIAS_PLAN_BIN") or env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
if runner == "" then
    verdict.emit("could-not-run:opencode-web-window-fixture:no-runner", 2)
end
local root = "target/opencode-web-window-fixture"
proc.run{ argv = { "rm", "-rf", root } }
fs.mkdir(root)
local base = {
    main = fs.read("crates/tillandsias-headless/src/main.rs"),
    browser = fs.read("crates/tillandsias-headless/src/browser_open.rs"),
    http = fs.read("crates/tillandsias-router-sidecar/src/http.rs"),
    otp = fs.read("crates/tillandsias-otp/src/lib.rs"),
}

local function plant(over)
    for k, t in pairs(base) do
        local file = ({ main = "main.rs", browser = "browser_open.rs", http = "http.rs", otp = "otp.rs" })[k]
        fs.write(root .. "/" .. file, (over and over[k]) or t)
    end
end

local function check()
    local r = proc.run{
        argv = { runner, "script", "run", "scripts/lua/check-opencode-web-window.lua" },
        env = { TILLANDSIAS_OPENCODE_WINDOW_SRC = root },
    }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end

local function replace_once(text, old, new, after)
    local from = after and assert(text:find(after, 1, true), "fixture anchor missing: " .. after) or 1
    local s, e = text:find(old, from, true)
    assert(s, "fixture anchor missing: " .. old)
    return text:sub(1, s - 1) .. new .. text:sub(e + 1)
end

local fails = 0
local function expect(cond, label, detail)
    if cond then
        log.raw("ok:   " .. label)
    else
        log.raw("FAIL: " .. label .. "\n" .. detail)
        fails = fails + 1
    end
end

plant()
local code, out = check()
expect(code == 0 and out:find("ok:opencode-web-window", 1, true), "GREEN: the tree passes", out)

local cases = {
    { "browser", ".network(&handle.network_name)", '.network("host")', "RED: host networking for the window", "pub(crate) fn app_window_spec(" },
    { "main", '"https://opencode.{project_label}.localhost:{}/"', '"http://opencode.{project_label}.localhost:{}/"', "RED: a plaintext window URL" },
    { "http", ".filter(|next| is_safe_landing_path(next))", ".filter(|_| true)", "RED: an unfiltered next" },
    { "otp", '&& !path.starts_with("//")', "", "RED: a landing check that accepts //host" },
}
for _, c in ipairs(cases) do
    plant({ [c[1]] = replace_once(base[c[1]], c[2], c[3], c[5]) })
    code, out = check()
    expect(code == 1 and out:find("violation:opencode-web-window:", 1, true), c[4], out)
end

proc.run{ argv = { "rm", "-rf", root } }
if fails > 0 then
    verdict.emit("violation:opencode-web-window-fixture:" .. fails, 1)
end
verdict.emit("ok:opencode-web-window-fixture:5", 0)
