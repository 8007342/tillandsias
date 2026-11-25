-- @env PATH HOME
-- @trace order:963-pdrp, spec:forge-environment-discoverability, order:2328-r8qf
--
-- test-mcp-plan-resolver-pinning.lua — the MCP servers (project-info.sh, forge-plan.sh) find
-- the plan ledger by the REPOSITORY and accept only a real Tillandsias ledger. Ported from the
-- .sh of the same name (2328-r8qf). Measured: a foreign repo's plan/index.yaml was promoted
-- into the plan lane, and a checkout that lost its marker dir fell back to a stale
-- $HOME/src/tillandsias clone. Both resolvers are extracted verbatim and must agree.
--
--   1 a FOREIGN repo's non-ledger resolves to nothing
--   2 a repo that lost plan/ resolves to nothing: no $HOME fallback inside a repo
--   3 a real ledger resolves to the REPO's, from a subdirectory too
--   4 outside any repo the $HOME ledger is found, and a non-ledger there is not
--   5 TILLANDSIAS_PLAN_INDEX overrides
--   6 plan_query from the sparse repo does not answer from the $HOME clone
--
-- Usage: tillandsias-plan script run scripts/lua/test-mcp-plan-resolver-pinning.lua
-- Verdict: ok:mcp-plan-resolver-pinning:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("mcp-plan-resolver-pinning")
local SH, ROOT, PLAN = fixture.posix_shell(), fixture.repo_root(), fixture.plan_binary()
local LEDGER = "plan_index:\n  version: 1\npackets:\n  - packet_id: stale-home-clone-packet\n    order: 1-home\n    status: ready\n    pickup_role: linux\n    title: from the STALE HOME CLONE\n"
-- Scratch is inside this checkout, so "outside any repo" needs a git ceiling there.
local d = T:scratch()
local function put(f, body)
    fs.mkdir(d.rel .. "/" .. f:match("^(.*)/")); fs.write(d.rel .. "/" .. f, body)
end
put("home/src/tillandsias/plan/index.yaml", LEDGER)
put("home2/src/tillandsias/plan/index.yaml", "roadmap: []\n")
put("foreign/plan/index.yaml", 'resource_changes: []\nformat_version: "1.2"\n')
put("runtime/plan/index.yaml", LEDGER)
for _, h in ipairs{ "home", "home2" } do fs.mkdir(d.rel .. "/" .. h .. "/src/tillandsias/plan/index.d") end
for _, p in ipairs{ "sparse", "runtime/sub", "runtime/plan/index.d", "foreign/plan/index.d", "norepo" } do fs.mkdir(d.rel .. "/" .. p) end
for _, p in ipairs{ "foreign", "sparse", "runtime" } do T:must{ "git", "init", "-q", d.abs .. "/" .. p } end

-- $1 cwd, $2 HOME, $3 TILLANDSIAS_PLAN_INDEX or empty, $4 git ceiling. Answers are printed
-- relative to the scratch root as the shell spells it.
local PRE = [==[
W="$(cd . && pwd -P)"
export GIT_CEILING_DIRECTORIES="$W" HOME="$W/$2"
unset CLAUDE_PROJECT_DIR PROJECT_ROOT
[ -z "$3" ] || export TILLANDSIAS_PLAN_INDEX="$W/$3"
cd "$W/$1" || exit 90
]==]
local function sh(body, cwd, home, index, stdin_env)
    return proc.run{ argv = { SH, "-s", "--", cwd, home or "home", index or "" }, cwd = d.abs, stdin = PRE .. body, env_unset = { "TILLANDSIAS_*" },
        env = stdin_env or { PATH = env.get("PATH"), HOME = env.get("HOME") }, timeout_ms = 60000 }
end
for _, name in ipairs{ "project-info", "forge-plan" } do
    local src = "\n" .. fs.read("images/default/config-overlay/mcp/" .. name .. ".sh")
    local fns = ""
    for _, f in ipairs{ "project_toplevel", "is_tillandsias_ledger", "resolve_plan_index" } do
        local body = src:match("\n(" .. f .. "%(%) {.-\n}\n)")
        if not body then T:refuse("no-subject", f .. "() is not in " .. name .. ".sh") end
        fns = fns .. body
    end
    local function res(cwd, home, index)
        local r = sh(fns .. 'p="$(resolve_plan_index </dev/null)"; printf "%s" "${p#"$W"/}"\n', cwd, home, index)
        return r.stdout or "", "[" .. (r.stdout or "") .. "] rc=" .. tostring(r.code) .. " " .. (r.stderr or "")
    end
    local OWN, HOME_ = "runtime/plan/index.yaml", "home/src/tillandsias/plan/index.yaml"
    local o, why = res("foreign")
    T:arm(name .. " 1 a foreign repo's non-ledger resolves to nothing", o == "", why)
    o, why = res("sparse")
    T:arm(name .. " 2 a repo without plan/ resolves to nothing", o == "", why)
    local x, y = res("runtime"), res("runtime/sub")
    T:arm(name .. " 3 a real ledger resolves to the repo's own, from a subdirectory too", x == OWN and y == OWN, x .. " " .. y)
    x, y = res("norepo"), res("norepo", "home2")
    T:arm(name .. " 4 outside any repo the $HOME ledger is found and a non-ledger there is not", x == HOME_ and y == "", x .. " | " .. y)
    o, why = res("foreign", "home", OWN)
    T:arm(name .. " 5 TILLANDSIAS_PLAN_INDEX overrides", o == OWN, why)
end
if PLAN ~= "" and fixture.which("jq") then
    local call = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"plan_query","arguments":{"status":"ready"}}}'
    local e = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = PLAN, R = ROOT, CALL = call }
    local ASK = 'printf "%s\\n" "$CALL" | bash "$R/images/default/config-overlay/mcp/project-info.sh" 2>/dev/null\n'
    local sparse, home = sh(ASK, "sparse", "home", nil, e).stdout or "", sh(ASK, "norepo", "home", nil, e).stdout or ""
    T:arm("6a CONTROL outside any repo plan_query does answer from the $HOME ledger", text.contains(home, "stale-home-clone-packet"), home:sub(1, 300))
    T:arm("6b plan_query from a repo without a ledger does not", sparse ~= "" and not text.contains(sparse, "stale-home-clone-packet"), sparse:sub(1, 300))
else
    out.line("skip: 6 no plan binary or no jq")
end
T:finish()
