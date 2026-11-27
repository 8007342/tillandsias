-- @trace order:2380-ds8v, order:482d, order:659-8faj, spec:forge-environment-discoverability
--
-- test-forge-discovery-cli.lua — tillandsias-inventory, -services and -models are stock Lua
-- commands of the forge image. A host has no lua, so each is loaded here with its io and os
-- answered by this fixture: every command line it builds still runs, in a real shell, over
-- stub tools (and the real jq).
--
-- Verdict: ok:forge-discovery-cli:<n> arms | violation:forge-discovery-cli:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("forge-discovery-cli")
local ROOT = fixture.repo_root()
local BASH, JQ = fixture.which("bash"), fixture.which("jq")
if not BASH then T:refuse("no-bash") end
if not JQ then T:skip("no-jq") end
local W = T:scratch()
fs.mkdir(W.rel .. "/bin")
local function stub(name, body) fs.write(W.rel .. "/bin/" .. name, "#!" .. BASH .. "\n" .. body); T:must{ "chmod", "+x", W.abs .. "/bin/" .. name } end
stub("java", 'printf "openjdk  17\\t  \\"x\\" \\nsecond line\\n" >&2\n')
stub("git", "exit 0\n")
stub("nc", '[ "$4" = proxy ]\n')
stub("curl", 'printf "%s" "$*" > "' .. W.abs .. '/curl-args"\n[ "$STUB" != down ] || exit 22\n[ "$STUB" != none ] || { printf \'{"models":[]}\'; exit 0; }\n'
    .. [[printf '%s' '{"models":[{"name":"qwen2.5:0.5b","size":397821319,"modified_at":"2026-01-02T03:04:05.6Z","digest":"a"},{"name":"qwen2.5:7b","size":1},{"name":"qwen2.5-coder:32b","size":1},{"name":"llama3.2:3b","size":1}]}']] .. "\n")
T:must{ "ln", "-s", JQ, W.abs .. "/bin/jq" }

-- call(tool, env, args...) -> stdout, stderr, exit code
local function call(tool, e, ...)
    local so, se, stop = {}, {}, {}
    local function sh(cmd)
        return T:run{ BASH, "-s", stdin = cmd .. "\n", cwd = ROOT, env = { PATH = W.abs .. "/bin", STUB = e.STUB } }
    end
    local function handle(s)
        return { read = function(_, how) if how == "a" then local r = s; s = ""; return r end local l, rest = s:match("^([^\n]*)\n?(.*)$"); if s == "" then return nil end s = rest; return l end,
            close = function() return true end }
    end
    local function sink(t) return { write = function(self, ...) for _, v in ipairs{ ... } do t[#t + 1] = v end return self end } end
    local world = { string = string, table = table, math = math, ipairs = ipairs, pairs = pairs, tonumber = tonumber, tostring = tostring, type = type,
        arg = { [0] = "/usr/local/bin/" .. tool, ... },
        io = { stdout = sink(so), stderr = sink(se), popen = function(c) return handle(sh(c).stdout or "") end,
            open = function(p)
                local in_repo, there = pcall(fs.exists, p) -- a path outside the repository refuses: absent
                if not (in_repo and there) then return nil end
                local l, i = text.lines(fs.read(p)), 0
                return { lines = function() return function() i = i + 1; return l[i] end end, close = function() end }
            end },
        os = { getenv = function(n) return e[n] end, execute = function(c) return sh(c).code == 0 or nil end, exit = function(c) stop.code = c; error(stop) end } }
    local src = fs.read("images/default/cli/" .. tool)
    local f, why = load((src:gsub("^#![^\n]*", "")), "=" .. tool, "t", world)
    if not f then return "", why, "load" end
    local ok, got = pcall(f)
    if not ok and got ~= stop then return table.concat(so), tostring(got), "error" end
    return table.concat(so), table.concat(se), stop.code or 0
end
local function get(doc, q)
    local r = T:run{ JQ, "-r", q, stdin = doc }
    return r.code == 0 and text.trim(r.stdout or "") or "unparsed: " .. doc
end

for _, t in ipairs{ "tillandsias-inventory", "tillandsias-services", "tillandsias-models" } do
    local o, err, rc = call(t, {}, "--help")
    T:arm(t .. " --help names its usage, rc 0", rc == 0 and o:find("\nUsage: " .. t .. " [--json]\n", 1, true), tostring(rc) .. err .. o)
    o, err, rc = call(t, {}, "--bogus")
    T:arm(t .. " refuses an unknown argument, rc 2, nothing on stdout", rc == 2 and o == "" and err:find("unknown arg '--bogus'", 1, true), tostring(rc) .. err .. o)
end

local o, err, rc = call("tillandsias-inventory", { TILLANDSIAS_IMAGE_VERSION = "1.2" })
T:arm("inventory lists what is there, with its version and path, and nothing else", rc == 0 and o:find("^Tillandsias forge inventory — image v1%.2\n\nLanguages\n  java ") and o:find('openjdk 17 "x"', 1, true)
    and o:find(W.abs .. "/bin/java\n", 1, true) and not o:find("cargo", 1, true) and not o:find("\nBuild\n", 1, true), err .. o)
T:arm("inventory says (unknown) for a tool that prints no version", o:find("\n  git +%(unknown%)"), o)
o, err, rc = call("tillandsias-inventory", {}, "--json")
T:arm("inventory --json: every category, empty ones too, and the image unset", rc == 0
    and get(o, '[.image_version, .languages[0].version, (.build|length), .web_api[0].tool, (keys|length)]|map(tostring)|join("|")') == 'unset|openjdk 17 "x"|0|curl|7', err .. o)

local GIT = "git-a%1b'c"
o, err, rc = call("tillandsias-services", { TILLANDSIAS_GIT_SERVICE = GIT })
T:arm("services probes each, quotes the host, and names the router", rc == 0 and o:find("\n  proxy +proxy:3128 +up ") and o:find("inference:11434 +unreachable ")
    and o:find("  git%-mirror +git%-a%%1b'c:9418 +unreachable ") and o:find("git clone git://" .. GIT .. "/<project>\n", 1, true) and o:find("opencode.<project>.localhost:8080", 1, true), err .. o)
stub("touched", ': > "' .. W.abs .. '/pwned"\n')
call("tillandsias-services", { TILLANDSIAS_GIT_SERVICE = "x'; touched; '" })
T:arm("services: a host cannot run a command", not fs.exists(W.rel .. "/pwned"), "the host was executed")
o = call("tillandsias-services", { TILLANDSIAS_PROJECT = "p" })
T:arm("services falls back to git-<project>", o:find("git-p:9418", 1, true), o)
o, err = call("tillandsias-services", { TILLANDSIAS_PROJECT = "p" }, "--json")
T:arm("services --json", get(o, '[.services[0].status, .services[1].host, (.services[2].port|type), .router.status]|join("|")') == "up|git-p|number|host-only", err .. o)

local M = { TILLANDSIAS_CLI_TIERS_DIR = "images/default/cli/tiers", TILLANDSIAS_INFERENCE_URL = "http://h:1/" }
o, err, rc = call("tillandsias-models", M, "--json")
T:arm("models prints the canonical table's tiers", rc == 0 and get(o, '[.models[]|.name+"="+.tier]|join(" ")') == "qwen2.5:0.5b=T0 qwen2.5:7b=T2 qwen2.5-coder:32b=T5 llama3.2:3b=--", err .. o)
T:arm("models asks the configured url, one slash", fs.read(W.rel .. "/curl-args"):find("http://h:1/api/tags", 1, true), fs.read(W.rel .. "/curl-args"))
call("tillandsias-models", { TILLANDSIAS_INFERENCE_URL = "http://h'; touched; '" })
T:arm("models: nor can a url", not fs.exists(W.rel .. "/pwned"), "the url was executed")
o = call("tillandsias-models", M)
T:arm("models text: MiB, and the time without its fraction", o:find("  T0   qwen2.5:0.5b                 379 MiB        2026-01-02T03:04:05\n", 1, true), o)
o, err, rc = call("tillandsias-models", { STUB = "down" })
T:arm("models unreachable: one line on stderr, rc 1", rc == 1 and o == "" and err == "inference container not running (http://inference:11434/api/tags unreachable)\n", tostring(rc) .. err .. o)
o, err, rc = call("tillandsias-models", { STUB = "down" }, "--json")
T:arm("models unreachable --json still parses, rc 1", rc == 1 and get(o, '.error+"|"+(.models|length|tostring)') == "inference container not running|0", o)
o, err, rc = call("tillandsias-models", { STUB = "none" })
T:arm("models none loaded, rc 0", rc == 0 and o == "no models loaded at http://inference:11434\n", tostring(rc) .. o)
o, err, rc = call("tillandsias-models", {})
T:arm("models without its tier table prints -- and still lists", rc == 0 and o:find("\n  --   qwen2.5:0.5b ", 1, true), tostring(rc) .. err .. o)
T:finish()
