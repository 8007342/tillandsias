-- @env PATH HOME TMPDIR
-- @trace order:1814-x78v, order:1815-tei4, order:2392-kww7, spec:expert-serve-grounded-pipeline, order:2367-d5gx
--
-- test-tellme-routes-to-expert-serve.lua — `tellme howto` and free-form `tellme about` answer through
-- expert-serve when it answers; only when it does not, the keyword-grep + /api/generate path runs,
-- labelled UNGROUNDED, naming the model the environment asks for. HERMETIC: a curl shim first on PATH
-- answers and records every request; no socket is opened. Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/test-tellme-routes-to-expert-serve.lua
-- Verdict: ok:tellme-routes-to-expert-serve:<n> arms | violation:...:<n>-failed
--        | skip:...:no-plan-binary | skip:...:no-jq-for-the-tellme-fallback

local fixture = require "common.fixture"
local T = fixture.new("tellme-routes-to-expert-serve")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
local SUBJECT = "images/default/cli/tellme"
if not fs.exists(SUBJECT) then T:refuse("subject-missing") end
if PLAN == "" then T:skip("no-plan-binary") end
if not fixture.which("jq") then T:skip("no-jq-for-the-tellme-fallback") end
local EXPERT, INFER = "http://127.0.0.1:65011", "http://inference.stub:11434"
local W = T:scratch()

fs.mkdir(W.rel .. "/cheatsheets/runtime")
fs.mkdir(W.rel .. "/bin")
fs.write(W.rel .. "/cheatsheets/INDEX.md", "# Cheatsheet index\n\n## runtime\n- runtime/database-containers.md — run a database container with rootless podman\n")
fs.write(W.rel .. "/cheatsheets/runtime/database-containers.md",
    "---\ntitle: database containers\n---\n# Database containers\nUse rootless podman: `podman run -d postgres:16`.\n")
-- Logs "<n> <url>" to calls.log and the body to body.<n>; a down expert is exit 7, could-not-connect.
fs.write(W.rel .. "/bin/curl", [=[
#!/usr/bin/env bash
log="$SHIM_DIR/calls.log"
n=$(( $( [ -f "$log" ] && wc -l < "$log" || echo 0 ) + 1 ))
url="" body=""
while [ $# -gt 0 ]; do
    case "$1" in
        -d|--data|--data-raw|--data-binary) body="$2"; shift 2 ;;
        --max-time|-m|-X|-H|-o|-w) shift 2 ;;
        http://*|https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$body" in @-) body="$(cat)" ;; @*) body="$(cat "${body#@}")" ;; esac
printf '%s %s\n' "$n" "$url" >> "$log"
printf '%s' "$body" > "$SHIM_DIR/body.$n"
case "$url" in
    "$SHIM_EXPERT"/*)
        [ ! -f "$SHIM_DIR/expert.down" ] || exit 7
        case "$url" in
            */v1/models) echo '{"object":"list","data":[{"id":"all","object":"model"},{"id":"cheatsheet","object":"model"}]}' ;;
            */v1/chat/completions) echo '{"id":"expert-serve-1","object":"chat.completion","model":"cheatsheet","choices":[{"index":0,"message":{"role":"assistant","content":"STUB-GROUNDED-ANSWER use podman run"},"finish_reason":"stop"}],"tillandsias_envelope":{"answer":"STUB-GROUNDED-ANSWER use podman run","citations":[{"path":"cheatsheets/runtime/forge-constraints.md","line_start":3,"line_end":9,"kind":"cheatsheet","authority":{}}]}}' ;;
            *) exit 22 ;;
        esac ;;
    "$SHIM_INFER"/api/tags) echo '{"models":[{"name":"qwen2.5:0.5b"},{"name":"llama3.2:3b"}]}' ;;
    "$SHIM_INFER"/api/generate) echo '{"response":"STUB-FALLBACK-ANSWER","done":true}' ;;
    *) exit 7 ;;
esac
]=])

-- tellme is stock Lua: it is loaded here with io.popen backed by proc.run of
-- the shell (the command line on stdin: the runtime refuses `sh -c <string>`).
proc.run{ argv = { "chmod", "+x", W.abs .. "/bin/curl" }, timeout_ms = 10000 }
local seq = 0
local function load_tellme(path, e, args)
    local so, stop = {}, {}
    local function sink(t) return { write = function(self, ...) for _, v in ipairs({ ... }) do t[#t + 1] = v end return self end,
        flush = function(self) return self end } end
    local world = { string = string, table = table, math = math, ipairs = ipairs, pairs = pairs, select = select,
        tonumber = tonumber, tostring = tostring, type = type,
        arg = { [0] = path, table.unpack(args) },
        io = { stdout = sink(so), stderr = sink(so), popen = function(c)
            local r = proc.run({ argv = { SH, "-s" }, stdin = c .. "\n", env = e, timeout_ms = 60000 })
            local s = r.stdout or ""
            return { read = function() local x = s; s = ""; return x end,
                close = function() return r.code == 0 or nil, "exit", r.code end }
        end },
        os = { getenv = function(n) return e[n] end, exit = function(c) stop.code = c; error(stop) end } }
    local f, why = load((fs.read(path):gsub("^#![^\n]*", "")), "=tellme", "t", world)
    if not f then return "load: " .. tostring(why) end
    local ok, got = pcall(f)
    if not ok and got ~= stop then so[#so + 1] = "error: " .. tostring(got) end
    return table.concat(so)
end
local function tellme(args, o)
    o = o or {}
    seq = seq + 1
    local tag = "c" .. seq
    local dir = W.rel .. "/" .. tag
    fs.mkdir(dir)
    if o.down then fs.write(dir .. "/expert.down", "") end
    local e = { PATH = W.abs .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin"), HOME = W.abs, SHIM_DIR = W.abs .. "/" .. tag,
        SHIM_EXPERT = EXPERT, SHIM_INFER = INFER, TELLME_EXPERT_URL = EXPERT, TILLANDSIAS_CHEATSHEETS = W.abs .. "/cheatsheets",
        TILLANDSIAS_INFERENCE_URL = INFER, TELLME_PLAN_BIN = PLAN, TILLANDSIAS_INFERENCE_MODEL = o.model,
        TILLANDSIAS_EXPERT_CONTEXT_PACK = o.pack and (W.abs .. "/" .. o.pack) or nil }
    local outp = load_tellme(o.subject or (ROOT .. "/" .. SUBJECT), e, args)
    local res = { out = outp, chat = {}, gen = {}, calls = 0 }
    if fs.exists(dir .. "/calls.log") then
        for n, url in fs.read(dir .. "/calls.log"):gmatch("(%d+) ([^\r\n]+)") do
            res.calls = res.calls + 1
            local kind = url:find("/v1/chat/completions$") and "chat" or url:find("/api/generate$") and "gen"
            if kind then
                local ok, j = pcall(json.parse, fs.read(dir .. "/body." .. n))
                res[kind][#res[kind] + 1] = ok and j or {}
            end
        end
    end
    res.got = "chat=" .. #res.chat .. " gen=" .. #res.gen .. " calls=" .. res.calls .. " " .. res.out:sub(1, 300)
    return res
end
local Q = "run a database container"

local r = tellme{ "howto", Q }
local m = r.chat[1] and r.chat[1].messages
T:arm("1 howto sends one chat completion to the cheatsheet model, and no generate", #r.chat == 1 and #r.gen == 0
    and r.chat[1].model == "cheatsheet" and m and m[#m].content == Q, r.got)
T:arm("1 and prints the answer with its citation", text.contains(r.out, "STUB-GROUNDED-ANSWER")
    and text.contains(r.out, "cheatsheets/runtime/forge-constraints.md:3-9"), r.got)
r = tellme{ "about", "how do I push from the forge" }
T:arm("2 a free-form about asks model all", #r.chat == 1 and r.chat[1].model == "all" and text.contains(r.out, "STUB-GROUNDED-ANSWER"), r.got)
r = tellme{ "about", "runtime" }
T:arm("2 CONTROL a slug is an index lookup that contacts nobody", r.calls == 0 and text.contains(r.out, "database-containers.md"), r.got)

local function ungrounded(x)
    local p = x.gen[1] and x.gen[1].prompt or ""
    return #x.gen == 1 and #x.chat == 0 and text.contains(p, "database-containers.md") and not text.contains(p:lower(), "general knowledge")
        and not text.contains(x.out:lower(), "general knowledge") and text.contains(x.out, "UNGROUNDED")
end
r = tellme({ "howto", Q }, { down = true })
T:arm("3 a closed port falls back once, with the grep context, labelled UNGROUNDED", ungrounded(r), r.got)
T:arm("4 CONTROL the fallback's default model", r.gen[1] and r.gen[1].model == "qwen2.5:0.5b", r.got)
r = tellme({ "howto", Q }, { down = true, model = "llama3.2:3b" })
T:arm("4 and the one the environment names", r.gen[1] and r.gen[1].model == "llama3.2:3b", r.got)

-- 5 the pack's exact bytes, then pipeline.rs's separator, then the system text.
local PACK = "# Forge context (generated at forge launch)\n\nPACK-LINE-2\n"
fs.write(W.rel .. "/pack.md", PACK)
local function head(x) return x.gen[1] and x.gen[1].prompt or "" end
r = tellme({ "howto", Q }, { down = true, pack = "pack.md" })
T:arm("5 the fallback prompt starts with the context pack and the separator", head(r):sub(1, #PACK + 14) == PACK .. "\n---\n\nSystem: ", head(r):sub(1, 90))
r = tellme({ "howto", Q }, { down = true, pack = "no-such-pack.md" })
T:arm("5 an absent pack leaves it starting at the system text", head(r):sub(1, 8) == "System: ", head(r):sub(1, 40))

-- MUTATION
local src = fs.read(SUBJECT):gsub("\r\n", "\n")
local function mutant(name, from, to)
    local a, b = src:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", name) end
    fs.write(W.rel .. "/" .. name, src:sub(1, a - 1) .. to .. src:sub(b + 1))
    return W.abs .. "/" .. name
end
r = tellme({ "howto", Q }, { subject = mutant("skips-expert", 'if expert_serve_ask("cheatsheet", query) then', "if false then") })
T:arm("6 MUTATION a howto that skips expert-serve fails arm 1", #r.chat == 0 and #r.gen == 1, r.got)
r = tellme({ "howto", Q }, { down = true, subject = mutant("unlabelled", "[UNGROUNDED: expert-serve", "[expert-serve") })
T:arm("6 MUTATION an unlabelled fallback fails arm 3", #r.gen == 1 and not ungrounded(r), r.got)
r = tellme({ "howto", Q }, { down = true, model = "llama3.2:3b", subject = mutant("fixed-model", 'env("TILLANDSIAS_INFERENCE_MODEL")\n', 'nil\n') })
T:arm("6 MUTATION a fallback that ignores the environment's model fails arm 4", r.gen[1] and r.gen[1].model ~= "llama3.2:3b", r.got)

T:finish()
