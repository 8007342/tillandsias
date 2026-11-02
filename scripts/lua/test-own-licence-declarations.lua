-- @trace order:1958-yfib
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-own-licence-declarations.lua — the licence-declaration guard refuses a
-- mislabelled file of ours and an image that leaves its licence label to the
-- base image, passes a vendored upstream licence, and says nothing on an empty
-- population. Scratch git repositories under target/plan-scratch/ hold:
--   ARM 1  a Containerfile with no org.opencontainers.image.licenses label  -> violation, by line
--   ARM 2  a crate's Cargo.toml declaring license = "MIT"                   -> violation, by line
--   ARM 3  a vendored upstream LICENSE under a listed path + labelled image -> ok
--   ARM 4  a repository with no Containerfile and no Cargo.toml             -> could-not-run, never ok
-- and ARM 5 runs the guard over the live checkout as it stands.
-- Red on the tree before 1958-yfib: ARM 5 refused 20 images (every
-- images/*/Containerfile* and observatorium/Containerfile inherited a label).
--
-- Usage: tillandsias-plan script run scripts/lua/test-own-licence-declarations.lua [-- --plan <bin>]
-- Verdict: ok:own-licence-declarations-fixture:5 | violation:own-licence-declarations-fixture:<arms failed>

local CHECK_REL = "scripts/lua/check-own-licence-declarations.lua"
local PLAN
for i = 1, #arg do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then PLAN = "tillandsias-plan" end

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 60000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
if ROOT == "" then verdict.could_not_run("own-licence-declarations-fixture", "not inside a git checkout") end
local check_src = fs.read(CHECK_REL)
if not check_src then verdict.could_not_run("own-licence-declarations-fixture", CHECK_REL .. " unreadable") end

local REL = "target/plan-scratch/own-licence-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
local failed, arms = {}, 0

local function scratch(name, files)
    local dir = REL .. "/" .. name
    fs.mkdir(dir .. "/scripts/lua")
    fs.write(dir .. "/scripts/lua/check-own-licence-declarations.lua", check_src)
    for path, body in pairs(files) do
        local d = path:match("^(.*)/[^/]+$")
        if d then fs.mkdir(dir .. "/" .. d) end
        fs.write(dir .. "/" .. path, body)
    end
    local abs = ROOT .. "/" .. dir
    run({ "git", "init", "-q", abs })
    run({ "git", "-C", abs, "add", "-A" })
    return abs
end
local function guard(abs)
    local r = run({ PLAN, "script", "run", "scripts/lua/check-own-licence-declarations.lua" }, { cwd = abs })
    local out = (r.stdout or "") .. "\n" .. (r.stderr or "")
    -- the verdict is the one line starting ok:/violation:/could-not-run:, wherever buffering put it
    local last = ""
    for _, l in ipairs(text.lines(r.stdout or "")) do
        if l:match("^ok:") or l:match("^violation:") or l:match("^could%-not%-run:") then last = l end
    end
    return last, out
end
local function arm(n, name, ok, detail)
    arms = arms + 1
    if not ok then failed[#failed + 1] = string.format("arm %d (%s): %s", n, name, detail) end
    log.raw(string.format("  arm %d %s: %s", n, ok and "ok" or "FAILED", name))
end

local LABELLED = 'FROM docker.io/library/alpine:3.20\nLABEL org.opencontainers.image.licenses="GPL-3.0-or-later"\n'
local WS_CRATE = '[package]\nname = "x"\nversion = "0.1.0"\nlicense.workspace = true\n'

-- ARM 1: an image with no licence label inherits its base's.
do
    local abs = scratch("arm1", {
        ["images/x/Containerfile"] = "FROM docker.io/library/alpine:3.20\nRUN true\n",
        ["crates/x/Cargo.toml"] = WS_CRATE,
    })
    local last, out = guard(abs)
    arm(1, "unlabelled image is refused by line",
        last == "violation:own-licence-declarations:1" and text.contains(out, "refused:images/x/Containerfile:image-inherits-base-licence-label"),
        "got `" .. last .. "`")
end
-- ARM 2: a crate of ours declaring MIT.
do
    local abs = scratch("arm2", {
        ["images/x/Containerfile"] = LABELLED,
        ["crates/x/Cargo.toml"] = '[package]\nname = "x"\nversion = "0.1.0"\nlicense = "MIT"\n',
    })
    local last, out = guard(abs)
    arm(2, "MIT on our own Cargo.toml is refused by line",
        last == "violation:own-licence-declarations:1" and text.contains(out, "refused:crates/x/Cargo.toml:cargo-license-not-gpl:MIT"),
        "got `" .. last .. "`")
end
-- ARM 3: a vendored upstream LICENSE on a listed path passes.
do
    local abs = scratch("arm3", {
        ["images/x/Containerfile"] = LABELLED,
        ["crates/x/Cargo.toml"] = WS_CRATE,
        ["crates/tillandsias-core/data/devices/upstream/thing-LICENSE"] = "Apache License\nVersion 2.0, January 2004\n",
    })
    local last = guard(abs)
    arm(3, "vendored upstream LICENSE passes", last:match("^ok:own%-licence%-declarations:checked=%d+$") ~= nil, "got `" .. last .. "`")
end
-- ARM 4: nothing to inspect is could-not-run, never ok.
do
    local abs = scratch("arm4", { ["README.md"] = "nothing here\n" })
    local last = guard(abs)
    arm(4, "empty population is could-not-run", last == "could-not-run:own-licence-declarations:empty-population", "got `" .. last .. "`")
end
-- ARM 5: the live tree.
do
    local last = guard(ROOT)
    arm(5, "live checkout passes", last:match("^ok:own%-licence%-declarations:checked=%d+$") ~= nil, "got `" .. last .. "`")
end

run({ "rm", "-rf", ROOT .. "/" .. REL })
if #failed > 0 then
    for _, f in ipairs(failed) do io.stdout:write(f .. "\n") end
    verdict.emit("violation:own-licence-declarations-fixture:" .. #failed, 1)
end
verdict.emit("ok:own-licence-declarations-fixture:" .. arms, 0)
