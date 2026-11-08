-- @trace order:2007-uvtl
-- @env PATH
--
-- test-uv-venv-survives-forge-replacement.lua — a venv on the persistent
-- project cache keeps a working bin/python when the forge container (and so
-- its $HOME) is replaced.
--   1 STATIC   lib-common.sh exports UV_PYTHON_INSTALL_DIR under $PROJECT_CACHE
--   2 FIX      with that dir: install a uv-managed Python, make a venv in
--              $PROJECT_CACHE/venvs, delete HOME, start with a new HOME:
--              the venv's bin/python still runs
--   3 CONTROL  the pre-fix shape (default install dir under HOME): the same
--              steps leave bin/python dangling, so arm 2 is not vacuous
-- Red before 2007-uvtl: arm 1 found no export, and arm 2 failed like arm 3.
-- Needs uv on PATH and the network for one Python download (could_not_run
-- otherwise).
--
-- Usage: tillandsias-plan script run scripts/lua/test-uv-venv-survives-forge-replacement.lua

local NAME = "uv-venv-survives-forge-replacement"
local PATH = env.get("PATH") or "/usr/bin:/bin"
local function sh(argv, envt, ms)
    envt = envt or {}
    envt.PATH = envt.PATH or PATH
    return proc.run({ argv = argv, env = envt, timeout_ms = ms or 60000 })
end

local top = sh({ "git", "rev-parse", "--show-toplevel" })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer")
end
local uvv = sh({ "uv", "--version" })
if uvv.status ~= "exited" or uvv.code ~= 0 then
    verdict.could_not_run(NAME, "uv is not on PATH")
end

local failed, passed = {}, 0
local function arm(name, cond, got)
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got):gsub("\n", " | "))
        failed[#failed + 1] = name
    end
end

-- 1 STATIC
local lib = fs.read("images/default/lib-common.sh") or ""
local val = lib:match('\nexport UV_PYTHON_INSTALL_DIR="([^"]*)"')
arm("1 STATIC lib-common exports UV_PYTHON_INSTALL_DIR under $PROJECT_CACHE",
    val ~= nil and val:sub(1, 15) == "$PROJECT_CACHE/", val)

local REL = "target/plan-scratch/uvtl" .. tostring(math.random(100000, 999999))
local DIR = ROOT .. "/" .. REL
local PC = DIR .. "/project-cache"
fs.mkdir(REL .. "/project-cache/venvs")

local function wipe(p)
    sh({ "find", p, "-mindepth", "0", "-delete" }, nil, 120000)
end

-- One forge lifetime: install, make the venv, then the container goes away.
local function lifetime(tag, install_dir)
    local home = DIR .. "/home-" .. tag
    fs.mkdir(REL .. "/home-" .. tag)
    local e = { HOME = home, UV_CACHE_DIR = PC .. "/uv", UV_PYTHON_PREFERENCE = "only-managed",
                UV_PYTHON_DOWNLOADS = "automatic" }
    if install_dir then e.UV_PYTHON_INSTALL_DIR = install_dir end
    local i = sh({ "uv", "python", "install", "3.12" }, e, 600000)
    if i.status ~= "exited" or i.code ~= 0 then
        verdict.could_not_run(NAME, "uv python install 3.12 failed (network?): " .. text.trim(i.stderr or ""))
    end
    local venv = PC .. "/venvs/" .. tag
    local v = sh({ "uv", "venv", venv, "--python", "3.12" }, e, 120000)
    if v.status ~= "exited" or v.code ~= 0 then
        verdict.could_not_run(NAME, "uv venv failed: " .. text.trim(v.stderr or ""))
    end
    local before = sh({ venv .. "/bin/python", "-c", "print('alive')" }, { HOME = home })
    wipe(home) -- the forge is replaced: its HOME is gone
    fs.mkdir(REL .. "/home-" .. tag .. "-next")
    local after = sh({ venv .. "/bin/python", "-c", "print('alive')" }, { HOME = home .. "-next" })
    return before, after
end

local ok_b, ok_a = lifetime("fix", val and (val:gsub("%$PROJECT_CACHE", PC)) or nil)
arm("2 FIX the venv's python runs after the forge's HOME is replaced",
    ok_b.code == 0 and ok_a.status == "exited" and ok_a.code == 0 and text.trim(ok_a.stdout or "") == "alive",
    (ok_a.code or ok_a.status) .. " " .. (ok_a.stderr or ""))

local c_b, c_a = lifetime("control", nil)
arm("3 CONTROL with the install dir under HOME the venv's python dangles",
    c_b.code == 0 and not (c_a.status == "exited" and c_a.code == 0),
    (c_a.code or c_a.status) .. " " .. (c_a.stdout or ""))

wipe(DIR)
if #failed > 0 then
    verdict.emit("violation:" .. NAME .. ":" .. table.concat(failed, ","), 1, #failed .. " arm(s) failed")
end
verdict.emit("ok:" .. NAME .. ":" .. passed .. " arms+control", 0)
