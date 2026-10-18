-- @trace order:1776-ch4m
-- @env PATH TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-launch-images-table.lua — scripts/lua/check-launch-images-table.lua:
--   1 LIVE        this tree's headless crate passes
--   2 PRE-FIX     the operator's hole: a module that runs chromium-framework
--                 (rustfmt's multi-line `ContainerSpec::new(format!(` shape)
--                 and never ensures it is refused, naming file and line
--   3 SITE        the same module naming LaunchSite::ChromiumWindow passes
--   4 ENSURE-LINE an ensure call quoting "webkit" covers its tag literal
--   5 DEPENDENCY  forge-base passes as the base of an ensured forge, and is
--                 refused alone (NEGATIVE CONTROL)
--   6 MARKED      `launch-images-ok:` in the comment block above passes
--   7 TEST-CODE   a literal inside a #[cfg(test)] module is not a literal
--   8 POPULATION  no literal at all is a refusal, not a pass
--
-- Usage: tillandsias-plan script run scripts/lua/test-launch-images-table.lua

local SUBJECT = "scripts/lua/check-launch-images-table.lua"
local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("launch-images-table-fixture", "no plan binary named (TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("launch-images-table-fixture", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/launch-images-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local function run(scan)
    local e = {}
    if scan then e.TILLANDSIAS_LAUNCH_IMAGES_SCAN = scan end
    local r = proc.run({ argv = { PLAN, "script", "run", SUBJECT }, cwd = ROOT, env = e, timeout_ms = 120000 })
    return r.code or -1, text.trim(r.stdout or "")
end

local TABLE = [[
pub(crate) fn launch_images(site: LaunchSite) -> &'static [&'static str] {
    match site {
        LaunchSite::EnclaveForProject => &["router", "git", "inference", "forge"],
        LaunchSite::ChromiumWindow => &["chromium-framework"],
    }
}
]]
local DEPS = [[
fn image_dependency(image_name: &str) -> Option<&'static str> {
    match image_name {
        "forge" => Some("forge-base"),
        "chromium-framework" => Some("chromium-core"),
        _ => None,
    }
}
]]
-- trunk's browser_open.rs forwarder_spec, the operator's hole
local WINDOW = [[
pub(crate) fn forwarder_spec() -> tillandsias_podman::ContainerSpec {
    tillandsias_podman::ContainerSpec::new(format!(
        "tillandsias-chromium-framework:v{}",
        crate::VERSION.trim()
    ))
    .pull_never()
}
]]

local n = 0
local function tree(files)
    n = n + 1
    local d = REL .. "/" .. n
    fs.mkdir(d)
    fs.write(d .. "/launch_images.rs", TABLE)
    for name, body in pairs(files) do fs.write(d .. "/" .. name, body) end
    return d
end

local rc, o = run(nil)
arm("1 LIVE this tree's headless crate passes",
    rc == 0 and o:find("^ok:launch%-images%-table:modules=%d+:literals=%d+") ~= nil, rc .. " " .. o)

local d = tree({ ["browser_open.rs"] = WINDOW })
rc, o = run(d)
arm("2 PRE-FIX a module running chromium-framework without an ensure is refused, naming file and line",
    rc == 1 and o:find("violation:launch-images-table:sites=1", 1, true) ~= nil
    and o:find("site: " .. d .. "/browser_open.rs:2: chromium-framework", 1, true) ~= nil, rc .. " " .. o)

d = tree({ ["browser_open.rs"] = WINDOW .. "fn site() -> LaunchSite { LaunchSite::ChromiumWindow }\n" })
rc, o = run(d)
arm("3 SITE the module naming LaunchSite::ChromiumWindow passes",
    rc == 0 and o:find(":literals=1:allowed=0", 1, true) ~= nil, rc .. " " .. o)

d = tree({ ["webkit.rs"] = 'fn f() {\n    crate::ensure_versioned_images(&root, &["webkit"], version, debug)?;\n    let tag = crate::versioned_image_tag("webkit", version);\n}\n' })
rc, o = run(d)
arm("4 ENSURE-LINE an ensure call quoting \"webkit\" covers its tag literal",
    rc == 0 and o:find(":literals=1:allowed=0", 1, true) ~= nil, rc .. " " .. o)

local BASE = 'fn vsock() {\n    let image = versioned_image_tag("forge-base", VERSION.trim());\n}\n'
d = tree({ ["main.rs"] = DEPS .. BASE .. "fn s() -> LaunchSite { LaunchSite::EnclaveForProject }\n" })
rc, o = run(d)
local dep_ok = rc == 0 and o:find(":literals=1:allowed=0", 1, true) ~= nil
local dep_o = rc .. " " .. o
d = tree({ ["main.rs"] = DEPS .. BASE })
rc, o = run(d)
arm("5 DEPENDENCY forge-base passes as the base of an ensured forge, and is refused alone",
    dep_ok and rc == 1 and o:find("main.rs:9: forge-base", 1, true) ~= nil, dep_o .. " / " .. rc .. " " .. o)

d = tree({ ["probe.rs"] = 'fn p() {\n    // launch-images-ok: a probe, never a launch;\n    // it falls back to :latest.\n    let t = crate::versioned_image_tag("router", v);\n}\n' })
rc, o = run(d)
arm("6 MARKED launch-images-ok in the comment block above passes",
    rc == 0 and o:find(":literals=1:allowed=1", 1, true) ~= nil, rc .. " " .. o)

d = tree({ ["lib.rs"] = BASE .. "\n#[cfg(test)]\nmod tests {\n    fn t() {\n        let s = \"{\";\n        let x = versioned_image_tag(\"web\", \"0.1\");\n    }\n}\n" .. "fn s() -> LaunchSite { LaunchSite::EnclaveForProject }\n" .. DEPS })
rc, o = run(d)
arm("7 TEST-CODE a literal inside a #[cfg(test)] module (with a stray brace in a string) is not a literal",
    rc == 0 and o:find(":literals=1:allowed=0", 1, true) ~= nil, rc .. " " .. o)

d = tree({ ["empty.rs"] = "fn nothing() {}\n" })
rc, o = run(d)
arm("8 POPULATION no literal at all is a refusal",
    rc == 1 and o:find("refused:launch-images-table:no-literals", 1, true) ~= nil, rc .. " " .. o)

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then verdict.emit("refused:launch-images-table-fixture:" .. #failed .. "-of-8", 1) end
verdict.emit("ok:launch-images-table-fixture:8", 0)
