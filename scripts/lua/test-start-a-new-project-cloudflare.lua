-- @trace spec:project-bootstrap-readme, order:1907-xhpx
-- @env PATH
--
-- test-start-a-new-project-cloudflare.lua — order 1907-xhpx.
--
-- A new website or Flutter app gets its Cloudflare files without anyone asking.
--
--   1 --stack web, no --deploy: wrangler.jsonc serving ./public, a page in
--     public/, .dev.vars.example, and .dev.vars in .gitignore
--   2 --stack flutter, no --deploy: wrangler.jsonc serves ./build/web as a
--     single-page app
--   3 the configs parse, name is the slug, compatibility_date is a date
--   4 no account id, token or secret-shaped value in any created file
--   5 --deploy none, --stack other and --stack flutter-flame write no
--     Cloudflare file
--   6 an existing wrangler.jsonc and .gitignore are kept byte for byte
--
-- Pre-fix result: FAILS at arm 1, scaffold.sh refused --deploy cloudflare and
-- wrote no wrangler.jsonc.
--
-- Usage: tillandsias-plan script run scripts/lua/test-start-a-new-project-cloudflare.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("start-a-new-project-cloudflare", "git rev-parse --show-toplevel did not answer")
end
local S = ROOT .. "/skills/start-a-new-project/scaffold.sh"
if not fs.exists(S) then
    verdict.emit("violation:start-a-new-project-cloudflare:no-subject", 1, S .. " does not exist (1907-xhpx)")
end
local W = ROOT .. "/target/plan-scratch/start-a-new-project-cloudflare-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(W)

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end
local function scaffold(dir, args)
    fs.mkdir(dir)
    local argv = { "bash", S, "--dir", dir, "--no-specs" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = 60000 })
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
-- jsonc <file> — the parsed config after dropping whole-line // comments, or nil.
local function jsonc(path)
    if not fs.exists(path) then return nil end
    local kept = {}
    for line in ((fs.read(path) or "") .. "\n"):gmatch("([^\n]*)\n") do
        if not line:match("^%s*//") then kept[#kept + 1] = line end
    end
    local ok, v = pcall(json.parse, table.concat(kept, "\n"))
    return ok and v or nil
end
local function has_line(s, line) return ("\n" .. (s or "") .. "\n"):find("\n" .. line .. "\n", 1, true) ~= nil end

-- 1
local P = W .. "/web"
local rc, o = scaffold(P, { "--name", "Webby Web", "--summary", "A small website.", "--stack", "web" })
local pc = jsonc(P .. "/wrangler.jsonc")
arm("1 --stack web gains wrangler.jsonc (./public), a page, .dev.vars.example and an ignored .dev.vars",
    rc == 0 and pc and pc.assets and pc.assets.directory == "./public" and fs.exists(P .. "/public/index.html")
    and fs.exists(P .. "/.dev.vars.example") and has_line(fs.exists(P .. "/.gitignore") and fs.read(P .. "/.gitignore"), ".dev.vars"),
    "rc=" .. tostring(rc) .. " out=" .. o)

-- 2
local F = W .. "/flut"
rc, o = scaffold(F, { "--name", "Pong Party", "--summary", "A pong game.", "--stack", "flutter" })
local fc = jsonc(F .. "/wrangler.jsonc")
arm("2 --stack flutter serves ./build/web as a single-page app",
    rc == 0 and fc and fc.assets and fc.assets.directory == "./build/web"
    and fc.assets.not_found_handling == "single-page-application", "rc=" .. tostring(rc) .. " out=" .. o)

-- 3
local d = pc and pc.compatibility_date or ""
arm("3 the configs parse, name is the slug, compatibility_date is a date",
    pc and fc and pc.name == "webby-web" and fc.name == "pong-party"
    and d:match("^20%d%d%-[01]%d%-[0-3]%d$") ~= nil,
    "names=" .. tostring(pc and pc.name) .. "," .. tostring(fc and fc.name) .. " date=" .. d)

-- 4
local leak
local token = string.rep("[%w_%-]", 32)
for _, f in ipairs({ P .. "/wrangler.jsonc", P .. "/.dev.vars.example", P .. "/public/index.html",
                     F .. "/wrangler.jsonc", F .. "/.dev.vars.example" }) do
    local s = (fs.exists(f) and fs.read(f) or ""):lower()
    if s:find("account_id", 1, true) or s:find("api_token", 1, true) or s:find("cloudflare_", 1, true)
        or s:find("secret%s*[:=]") or s:find(token) then leak = f end
end
arm("4 no account id, token or secret-shaped value in the created files",
    leak == nil and pc ~= nil, "leak in " .. tostring(leak))

-- 5
local r1 = scaffold(W .. "/none", { "--name", "Plain", "--summary", "x.", "--stack", "web", "--deploy", "none" })
local r2 = scaffold(W .. "/other", { "--name", "Other", "--summary", "x.", "--stack", "other" })
local r3 = scaffold(W .. "/flame", { "--name", "Flame", "--summary", "x.", "--stack", "flutter-flame" })
local stray = {}
for _, f in ipairs({ "none/wrangler.jsonc", "other/wrangler.jsonc", "flame/wrangler.jsonc", "none/.dev.vars.example" }) do
    if fs.exists(W .. "/" .. f) then stray[#stray + 1] = f end
end
arm("5 --deploy none, --stack other and flutter-flame write no Cloudflare file",
    r1 == 0 and r2 == 0 and r3 == 0 and #stray == 0,
    "rc=" .. tostring(r1) .. "/" .. tostring(r2) .. "/" .. tostring(r3) .. " stray=" .. table.concat(stray, " "))

-- 6
local K = W .. "/keep"; fs.mkdir(K)
local MINE_W, MINE_G = '{ "name": "mine" }\n', "node_modules\n.dev.vars\n"
fs.write(K .. "/wrangler.jsonc", MINE_W); fs.write(K .. "/.gitignore", MINE_G)
rc = scaffold(K, { "--name", "Keep", "--summary", "x.", "--stack", "web" })
arm("6 an existing wrangler.jsonc and .gitignore are kept",
    rc == 0 and fs.read(K .. "/wrangler.jsonc") == MINE_W and fs.read(K .. "/.gitignore") == MINE_G, "rc=" .. tostring(rc))

proc.run({ argv = { "rm", "-rf", W }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:start-a-new-project-cloudflare:" .. #failed .. "-failed", 1)
end
verdict.ok("start-a-new-project-cloudflare", "6 arms")
