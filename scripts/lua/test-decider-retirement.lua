-- @env PATH HOME
-- @trace order:1443-xkwb, order:2222-icbs, order:2377-znx4
--
-- test-decider-retirement.lua — check-decider-retirement.lua retires a shell decider only when its
-- population is bootstrap scripts alone, never on an empty scan. Ported from the .sh of the same
-- name (2377-znx4). Scratch trees; the last of arm 2 and arm 4 read this checkout.
--
--   1 each decider answers on a bootstrap-only tree and prints its population
--   2 bootstrap-only: all three retire; one migratable script keeps them live; so does this tree
--   3 an empty tree is blocked for all three, never retire
--   4 the allowlist is the §6.5 table, has no dangling entry, and refuses one
--
-- Usage: tillandsias-plan script run scripts/lua/test-decider-retirement.lua
-- Verdict: ok:decider-retirement:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("decider-retirement")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
local RETIRE, ALLOW = ROOT .. "/scripts/lua/check-decider-retirement.lua", "scripts/portability/bootstrap-shell-allowlist.txt"
local function run(argv, cwd, more)
    local e = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = PLAN }
    for k, v in pairs(more or {}) do e[k] = v end
    local r = proc.run{ argv = argv, cwd = cwd, env = e, env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = 120000 }
    local o = text.trim((r.stdout or ""):gsub("\r", ""))
    return { rc = r.code, out = o, last = o:match("[^\n]*$"), err = "\n" .. (r.stderr or ""), why = "rc=" .. tostring(r.code) .. " [" .. o:sub(1, 400) .. "] " .. (r.stderr or ""):sub(1, 200) }
end
local function tree(...)
    local g = T:git_repo()
    fs.mkdir(g.rel .. "/scripts/hooks")
    for _, f in ipairs{ ... } do fs.write(g.rel .. "/" .. f, "#!/usr/bin/env bash\nset -euo pipefail\necho hi\n") end
    T:must{ "git", "-C", g.abs, "add", "-A" }
    T:must{ "git", "-C", g.abs, "commit", "-qm", "fixture", "--allow-empty" }
    return g.abs
end
local function decider(name, d)
    if name == "check-bash-dialect" then return run({ PLAN, "script", "run", ROOT .. "/scripts/lua/check-bash-dialect.lua" }, d, { TILLANDSIAS_REPO_ROOT = d }) end
    if name == "check-jq-callsite-ratchet" then return run({ SH, ROOT .. "/scripts/" .. name .. ".sh", "--root", d }, ROOT) end
    return run({ SH, ROOT .. "/scripts/" .. name .. ".sh" }, ROOT, { TILLANDSIAS_SIGPIPE_ROOT = d })
end
local function retire(d, more) return run(d and { PLAN, "script", "run", RETIRE, "--", "--root", d } or { PLAN, "script", "run", RETIRE }, ROOT, more) end
local DECIDERS = { "check-bash-dialect", "check-sigpipe-verdict-pipelines-added", "check-jq-callsite-ratchet" }
local function retired(x)
    local n = 0
    for _, d in ipairs(DECIDERS) do
        if text.contains("\n" .. x.out, "\nretire:" .. d .. " ") then n = n + 1 end
    end
    return n
end
local BOOT = tree("scripts/install.sh", "scripts/ensure_toolbox.sh", "scripts/hooks/pre-commit-openspec.sh", "build.sh", "launch.sh")
local CLEAN = { "ok:bash-dialect-clean", "ok:sigpipe-verdict-added:base-unavailable", "ok:jq-callsites:0:floor:0" }
for i, n in ipairs(DECIDERS) do
    local x = decider(n, BOOT)
    T:arm("1 " .. n .. " answers " .. CLEAN[i] .. " and prints its population", x.out == CLEAN[i] and x.err:find("\npopulation=%d+ bootstrap=%d+\n") ~= nil, x.why)
end
local x = retire(BOOT)
T:arm("2a a bootstrap-only tree retires all three", x.rc == 0 and retired(x) == 3 and x.last == "ok:decider-retirement:0 live", x.why)
x = retire(tree("scripts/install.sh", "build.sh", "launch.sh", "scripts/migratable.sh"))
T:arm("2b one migratable script keeps all three live", x.rc == 0 and x.last == "ok:decider-retirement:3 live" and not text.contains("\n" .. x.out, "\nretire:"), x.why)
x = retire()
T:arm("2c this tree: three live", x.rc == 0 and x.last == "ok:decider-retirement:3 live", x.why)
local EMPTY = tree()
local BLOCKED = { "blocked:bash-dialect:scan-empty", "blocked:sigpipe-verdict-added:scan-empty", "blocked:jq-ratchet-empty-population" }
for i, n in ipairs(DECIDERS) do
    x = decider(n, EMPTY)
    T:arm("3a " .. n .. " refuses an empty scripts/", x.out == BLOCKED[i], x.why)
end
x = retire(EMPTY)
T:arm("3b an empty tree is blocked for all three, never retire", x.rc == 1 and retired(x) == 0 and select(2, ("\n" .. x.out):gsub("\nblocked:decider%-retirement:check%-", "")) == 3, x.why)

local entries, want, dangling = {}, {}, {}
for l in fs.read(ALLOW):gmatch("[^\n]+") do
    local p = l:match("^%s*([^#%s]%S*)")
    if p then entries[#entries + 1] = p end
end
-- §6.5: the fixed rows, then what its globs resolve to.
for _, f in ipairs{ "build.sh", "launch.sh", "scripts/install.sh", "scripts/install-macos.sh", "scripts/ensure_toolbox.sh", "scripts/check-yaml-reader-availability.sh", "scripts/check-issue-citation-convention.sh", "scripts/check-gate-memory-floor.sh" } do want[#want + 1] = f end
for f in T:must{ "git", "-C", ROOT, "ls-files", "--", "scripts/*.ps1", "scripts/hooks/*.sh", "images/*/entrypoint*.sh" }.stdout:gmatch("[^\r\n]+") do want[#want + 1] = f end
table.sort(entries); table.sort(want)
T:arm("4a the allowlist is the §6.5 table", #entries > 8 and table.concat(entries, "\n") == table.concat(want, "\n"), table.concat(entries, " ") .. " / " .. table.concat(want, " "))
for _, p in ipairs(entries) do
    if not fs.exists(p) then dangling[#dangling + 1] = p end
end
T:arm("4b no entry dangles", #dangling == 0, table.concat(dangling, " "))
local d = T:scratch()
fs.write(d.rel .. "/allow.txt", fs.read(ALLOW) .. "\nscripts/no-such-bootstrap.sh\n")
x = retire(nil, { TILLANDSIAS_BOOTSTRAP_ALLOWLIST = d.abs .. "/allow.txt" })
T:arm("4c a dangling entry is refused before anything runs", x.rc == 1 and x.out == "blocked:decider-retirement:dangling-allowlist-entry:scripts/no-such-bootstrap.sh", x.why)
T:finish()
