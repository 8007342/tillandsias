-- @trace order:1312-i6da, spec:git-mirror-service, order:2170-ji2b
-- @env PATH HOME XDG_RUNTIME_DIR TILLANDSIAS_PROJECT
--
-- check-bare-metal-host-initialized.lua — is THIS bare-metal host's own enclave
-- and per-project git mirror up? NON-MUTATING: it starts nothing, stops nothing
-- and writes nothing. It only reports, and names the command that would fix what
-- it found. Ported from the .sh of the same name (order 2170-ji2b); every
-- verdict line and exit code is byte-identical (the todo: prefix is 2169-tdop).
--
-- WHY A CHECKER AND NOT JUST THE SKILL. The skill's two commands are
-- ensure-shaped, so running them is the remedy for almost everything. That is
-- exactly why a separate READ is needed: without it "did it work?" is answered by
-- running the remedy again, which cannot tell a healthy host from one repaired on
-- every check and broken in between.
--
-- VERDICTS, one line on stdout:
--   ok:bare-metal-host:<host>:enclave=up mirror=up router=up inference=up github=<seeded|not-seeded> lane=<…>   exit 0
--   todo:initialize-bare-metal-host:<component>:<command that fixes it>   exit 1
--   skip:bare-metal-host:<reason>                                          exit 0
--
-- github= is reported ONLY on the ok: path, where the mirror is up and can be
-- asked; saying "not-seeded" when the question could not be put is the
-- confident-wrong verdict shape this tree keeps paying for (894-scxy).
--
-- Usage: tillandsias-plan script run scripts/lua/check-bare-metal-host-initialized.lua

local E = { PATH = env.get("PATH"), HOME = env.get("HOME"), XDG_RUNTIME_DIR = env.get("XDG_RUNTIME_DIR") }
local function run(argv)
    return proc.run({ argv = argv, env = E, timeout_ms = 60000 })
end
local function trim(s) return text.trim(s or "") end

local PROJECT = env.get("TILLANDSIAS_PROJECT")
if PROJECT == nil or PROJECT == "" then PROJECT = "tillandsias" end
local HOST = ""
for _, argv in ipairs({ { "hostname", "-s" }, { "hostname" } }) do
    local r = run(argv)
    if r.status == "exited" and r.code == 0 and trim(r.stdout) ~= "" then HOST = trim(r.stdout); break end
end
if HOST == "" then HOST = "unknown" end
local MIRROR = "tillandsias-git-" .. PROJECT
local ENSURE_CMD = "tillandsias --ensure-enclave"

-- ORDER 1356-u6xe / 776-jcf3: the lane command is the cloud form, its
-- owner/repo read from this checkout's GitHub origin (to print the command
-- only); a non-GitHub origin prints a placeholder owner.
local nwo = trim(run({ "git", "remote", "get-url", "origin" }).stdout):gsub("%.git$", "")
local gh = nwo:match("^https://github%.com/(.+/.+)$") or nwo:match("^git@github%.com:(.+/.+)$")
nwo = gh or ("<owner>/" .. PROJECT)
local LANE_CMD = "tillandsias --cloud " .. nwo .. " --bash"

local ps = run({ "podman", "ps", "--format", "{{.Names}}" })
if ps.status ~= "exited" or ps.code == 127 then verdict.emit("skip:bare-metal-host:no-podman", 0) end
local running = {}
for _, n in ipairs(text.lines(ps.stdout or "")) do running[trim(n)] = true end

-- ORDER MATTERS AND IS NOT COSMETIC: vault before proxy before mirror. The
-- mirror's Vault Agent cannot authenticate without vault, so reporting the
-- mirror first would send a reader to restart a container whose dependency is
-- the actual fault.
for _, c in ipairs({
    { "tillandsias-vault", "vault", ENSURE_CMD }, { "tillandsias-proxy", "proxy", ENSURE_CMD },
    { MIRROR, "mirror", LANE_CMD }, { "tillandsias-router", "router", LANE_CMD },
    { "tillandsias-inference", "inference", LANE_CMD },
}) do
    if not running[c[1]] then verdict.emit("todo:initialize-bare-metal-host:" .. c[2] .. ":" .. c[3], 1) end
end

-- THE GITHUB FIELD IS A READ, NEVER A SEED. It asks the mirror's OWN Vault Agent
-- token whether secret/github/token is readable and non-empty, inside the
-- container (the token never crosses onto this host's argv). It never prints the
-- value, never writes, never prompts; seeding is the operator's act.
local len = trim(run({ "podman", "exec", MIRROR, "sh", "-c", [[
    T="$(cat /tmp/tillandsias-vault-token 2>/dev/null)"
    [ -n "$T" ] || exit 0
    curl -s --cacert /etc/tillandsias/ca.crt -H "X-Vault-Token: $T" \
        https://vault:8200/v1/secret/data/github/token 2>/dev/null \
      | jq -r "(.data.data.token // \"\") | length" 2>/dev/null
]] }).stdout)
local github = "not-seeded"
if len:match("^%d+$") and tonumber(len) > 0 then github = "seeded" end

-- ORDER 1313-prin. THE LANE FIELD reports what can be READ (the lane is proven
-- only by the skill's three acceptance legs). NOT pgrep: sshd retitles itself,
-- and 'pgrep -f sshd' matches this probe's own command line (1287-myx8); the
-- pid file is written by sshd itself.
local lane = "off"
local flag = run({ "podman", "exec", MIRROR, "sh", "-c", 'echo "${TILLANDSIAS_MIRROR_SSHD:-0}"' }).stdout or ""
flag = flag:gsub("[\r\n ]", "")
if flag == "1" then
    local up = run({ "podman", "exec", MIRROR, "sh", "-c",
        'p=$(cat /tmp/tillandsias-sshd/sshd.pid 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null' })
    if not (up.status == "exited" and up.code == 0) then
        lane = "unwired:sshd-not-running"
    else
        local pr = run({ "podman", "exec", MIRROR, "sh", "-c",
            'grep -h "^til:host-push:" /tmp/tillandsias-sshd/authorized_principals 2>/dev/null | head -1' }).stdout or ""
        pr = pr:gsub("[\r\n ]", "")
        lane = pr ~= "" and ("wired:" .. pr) or "unwired:no-host-principal"
    end
end

verdict.emit("ok:bare-metal-host:" .. HOST .. ":enclave=up mirror=up router=up inference=up github="
    .. github .. " lane=" .. lane, 0)
