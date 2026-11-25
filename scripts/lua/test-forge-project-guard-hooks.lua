-- @trace order:969-nhh7, order:1083-gzqj, order:1446-xqi6, order:2355-ncuh, spec:forge-environment-discoverability
--
-- test-forge-project-guard-hooks.lua — the forge installs the project's guard hooks
-- REPO-LOCAL and leaves the GLOBAL hooks dir alone. A global guard fires in every repo on
-- the box (2026-09-01: six litmus suites and a red gate). It CANNOT prove a hook fires;
-- 969-nhh7's live negative control does. Ported from the .sh (2355-ncuh).
--
--   1 a Tillandsias checkout gets repo-local core.hooksPath and the guards
--   2 the GLOBAL hooks dir is untouched
--   3 the agent trailer hook survives the repo-local shadowing
--   4 another project: untouched with no runnable plan binary; with one, its discipline
--     hooks go repo-local (1446-xqi6)
--   5 a missing checkout, or an empty path, is a silent no-op
--   6 the state line reports present and absent truthfully
--   7 the real checkout's local hooksPath is unchanged
-- The functions are EXTRACTED: lib-common.sh hard-fails at source time outside the image.
--
-- Verdict: ok:forge-project-guard-hooks:<n> arms | violation:forge-project-guard-hooks:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("forge-project-guard-hooks")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local PLAN = fixture.plan_binary()
local W = T:scratch()

local fns = { "trace_lifecycle() { :; }" }
for _, name in ipairs{ "install_project_guard_hooks", "install_project_discipline_hooks", "forge_hook_state_line" } do
    local p = false
    for l in (fs.read("images/default/lib-common.sh") .. "\n"):gmatch("([^\n]*)\n") do
        if l == name .. "() {" then p = true end
        if p then fns[#fns + 1] = l end
        if p and l == "}" then break end
    end
    if not p then T:refuse("no-subject", name .. " not found in images/default/lib-common.sh") end
end
fs.write(W.rel .. "/fns.sh", table.concat(fns, "\n") .. "\n")

local GLOBAL = W.rel .. "/home/.cache/tillandsias/git-hooks"
fs.mkdir(GLOBAL)
fs.write(GLOBAL .. "/prepare-commit-msg", "#!/bin/sh\n# TILLANDSIAS_AGENT trailer fixture\nexit 0\n")
fs.write(GLOBAL .. "/post-commit", "#!/bin/sh\n# experts-refresh-on-commit fixture\nexit 0\n")
T:must{ "chmod", "+x", W.abs .. "/home/.cache/tillandsias/git-hooks/prepare-commit-msg", W.abs .. "/home/.cache/tillandsias/git-hooks/post-commit" }
local function global_set()
    local names = {}
    for _, f in ipairs(fs.list(GLOBAL)) do names[#names + 1] = (tostring(f):match("([^/]+)$")) end
    table.sort(names)
    return table.concat(names, " ")
end
local global_before = global_set()

-- The checkout needs the installer plus every hook source it composes. DERIVED from the
-- installer (1083-gzqj): a typed-out list failed as an installation fault when it went
-- stale. The floor of 2 is CHOSEN: a pre-commit and at least one pre-push source; fewer
-- means this vacuity check's derivation broke.
local src, seen, hooks = fs.read("scripts/install-hooks.sh"), {}, {}
for p in src:gmatch("scripts/hooks/[a-z0-9-]+%.sh") do
    if not seen[p] then seen[p] = true; hooks[#hooks + 1] = p end
end
T:arm("0 the hook sources derive from install-hooks.sh", #hooks >= 2, "derived only " .. #hooks)
local proj = T:git_repo("proj")
fs.mkdir(proj.rel .. "/scripts/hooks")
fs.write(proj.rel .. "/scripts/install-hooks.sh", src)
for _, p in ipairs(hooks) do
    if not fs.exists(p) then
        T:arm("0 install-hooks.sh names " .. p, false, "it does not exist: the installer's set and the tree disagree; not an installation fault")
    else
        fs.write(proj.rel .. "/" .. p, fs.read(p))
    end
end
fs.write(proj.rel .. "/scripts/dev-host-experts.sh", fs.read("scripts/dev-host-experts.sh"))
T:must{ "git", "-C", proj.abs, "add", "-A" }
T:must{ "git", "-C", proj.abs, "commit", "-qm", "base" }
local bare, other, other2 = T:git_repo("bare"), T:git_repo("other"), T:git_repo("other2")

-- Run with a scratch HOME from a dir git cannot look above: the functions must never see
-- the real checkout. `x NAME FILE` says whether FILE is executable.
local function sh(body, e)
    local envs = { HOME = W.abs .. "/home", GIT_CONFIG_NOSYSTEM = "1", GIT_CEILING_DIRECTORIES = W.abs:match("^(.*)/") }
    for k, v in pairs(e or {}) do envs[k] = v end
    fs.write(W.rel .. "/run.sh", '. "' .. W.abs .. '/fns.sh"\nx() { [ -x "$2" ] && echo "$1=yes" || echo "$1=no"; }\n' .. body)
    local r = T:run{ SH, W.abs .. "/run.sh", cwd = W.abs, env = envs, env_unset = { "TILLANDSIAS_*", "GIT_*", "CARGO_TARGET_DIR", "XDG_CONFIG_HOME" } }
    local f = { raw = "rc=" .. tostring(r.code) .. " " .. ((r.stdout or "") .. (r.stderr or "")):gsub("\n", " | ") }
    for k, v in (r.stdout or ""):gmatch("([%w_]+)=([^\n]*)\n") do f[k] = v end
    return f
end
local function install(dir, e)
    return sh('install_project_guard_hooks "' .. dir .. '" >/dev/null 2>&1; echo "irc=$?"\n'
        .. '[ -n "' .. dir .. '" ] && [ -d "' .. dir .. '" ] || exit 0\necho "hp=$(git -C "' .. dir .. '" config --local --get core.hooksPath)"\n'
        .. 'for h in pre-commit pre-push prepare-commit-msg; do x "x_${h//-/_}" "' .. dir .. '/.git/hooks/$h"; done\n'
        .. "printf 'line:%s\\n' \"$(forge_hook_state_line \"" .. dir .. "\")\"\n", e)
end
local function real_hooks_path() return T:run{ "git", "-C", ROOT, "config", "--local", "--get", "core.hooksPath" }.stdout or "" end
local real_before = real_hooks_path()

local f = install(proj.abs)
T:arm("1 the installer returns zero", f.irc == "0", f.raw)
T:arm("1 core.hooksPath is set repo-local", f.hp == proj.abs .. "/.git/hooks", f.raw)
T:arm("1 pre-commit and pre-push are installed repo-local", f.x_pre_commit == "yes" and f.x_pre_push == "yes", f.raw)
T:arm("2 the GLOBAL hooks dir is untouched", global_set() == global_before, global_before .. " -> " .. global_set())
T:arm("3 the agent trailer hook is carried into the repo-local dir", f.x_prepare_commit_msg == "yes", f.raw)
T:arm("6 the state line reports present", f.raw:find("line:hooks: pre_push=present pre_commit=present dir=", 1, true), f.raw)

f = install(other.abs, { TILLANDSIAS_PLAN_BIN = W.abs .. "/no-such-plan", PATH = "/usr/bin:/bin" })
T:arm("4 with no runnable plan binary another project is untouched", f.irc == "0" and f.hp == "", f.raw)
if PLAN == "" then
    out.line("skip: arm 4b needs a runnable tillandsias-plan")
else
    f = install(other2.abs, { TILLANDSIAS_PLAN_BIN = PLAN })
    T:arm("4 with a plan binary another project gets its hooks repo-local, global dir untouched",
        f.hp == other2.abs .. "/.git/hooks" and f.x_pre_push == "yes" and global_set() == global_before, f.raw)
end
f = install(W.abs .. "/nope")
T:arm("5 a missing checkout is a silent no-op", f.irc == "0", f.raw)
f = install("")
T:arm("5 an empty path is a silent no-op", f.irc == "0", f.raw)
f = sh('printf "line:%s\\n" "$(forge_hook_state_line "' .. bare.abs .. '")"\n')
T:arm("6 the state line reports absent for an unguarded checkout", f.raw:find("line:hooks: pre_push=absent pre_commit=absent dir=", 1, true), f.raw)
T:arm("7 the real checkout's local hooksPath is unchanged", real_hooks_path() == real_before, real_before .. " -> " .. real_hooks_path())
T:finish()
