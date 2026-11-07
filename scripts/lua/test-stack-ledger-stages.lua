-- @trace order:1958-yfib
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-stack-ledger-stages.lua — the stack ledger generator DISCOVERS npm
-- lockfiles from the Containerfiles (never a hand list) and reads each
-- package's link kind from the stage that installs it:
--   ARM 1  images/x: a multi-stage image; builder stage `npm ci` on
--          build/package-lock.json, final stage COPY --from=builder /build/public
--          -> a production package is link=bundled-file; esbuild (a plain dependency
--             the stage EXECUTES via node_modules/.bin), its @esbuild/* variants and a
--             devDependency are link=build-stage-only
--   ARM 2  images/y: single stage `npm ci --omit=dev`
--          -> a production package is link=container-image, a dev package is
--             build-stage-only (omitted from the image)
--   ARM 3  images/z: a lockfile the Containerfile never installs -> link=unknown
--   ARM 4  every lockfile above was found without being named anywhere
-- Red before 1958-yfib's stage pass: the generator parsed two hard-coded
-- lockfiles (web-wrangler, observatorium) and called every package
-- container-image, so x, y and z produced no npm nodes at all.
--
-- Usage: tillandsias-plan script run scripts/lua/test-stack-ledger-stages.lua [-- --plan <bin>]
-- Verdict: ok:stack-ledger-stages-fixture:4 | violation:stack-ledger-stages-fixture:<arms failed>

local GEN_REL = "scripts/lua/build-stack-ledger.lua"
local PLAN
for i = 1, #arg do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then PLAN = "tillandsias-plan" end

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 120000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
if ROOT == "" then verdict.could_not_run("stack-ledger-stages-fixture", "not inside a git checkout") end
local gen_src = fs.read(GEN_REL)
if not gen_src then verdict.could_not_run("stack-ledger-stages-fixture", GEN_REL .. " unreadable") end

local REL = "target/plan-scratch/stack-ledger-stages-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
local DIR = ROOT .. "/" .. REL
local function put(path, body)
    local d = path:match("^(.*)/[^/]+$")
    if d then fs.mkdir(REL .. "/" .. d) end
    fs.write(REL .. "/" .. path, body)
end
local function lock(prod, dev)
    return '{"name":"fx","lockfileVersion":3,"packages":{"":{"name":"fx"},'
        .. '"node_modules/' .. prod .. '":{"version":"1.0.0","license":"MIT"},'
        .. '"node_modules/' .. dev .. '":{"version":"2.0.0","license":"Apache-2.0","dev":true}}}'
end
fs.mkdir(REL .. "/scripts/lua")
put("scripts/lua/build-stack-ledger.lua", gen_src)
put("meta.json", '{"packages":[],"workspace_members":[],"resolve":{"nodes":[]}}')
put("LICENSE", "GNU GENERAL PUBLIC LICENSE\n")
put("images/x/Containerfile", table.concat({
    "FROM docker.io/library/node:22-bookworm-slim AS builder",
    "WORKDIR /build",
    "COPY build/package.json build/package-lock.json /build/",
    "RUN npm ci --ignore-scripts",
    "COPY build/editor.jsx /build/",
    "RUN mkdir -p /build/public && node_modules/.bin/esbuild editor.jsx --bundle --outfile=public/editor.js",
    "FROM docker.io/library/node:22-bookworm-slim",
    'LABEL org.opencontainers.image.licenses="GPL-3.0-or-later"',
    "WORKDIR /opt/studio",
    "COPY --from=builder /build/public /opt/studio/public",
    "",
}, "\n"))
put("images/x/build/package-lock.json", '{"name":"fx","lockfileVersion":3,"packages":{"":{"name":"fx"},'
    .. '"node_modules/react":{"version":"1.0.0","license":"MIT"},'
    .. '"node_modules/esbuild":{"version":"3.0.0","license":"MIT"},'
    .. '"node_modules/@esbuild/linux-x64":{"version":"3.0.0","license":"MIT","optional":true},'
    .. '"node_modules/typescript":{"version":"2.0.0","license":"Apache-2.0","dev":true}}}')
put("images/x/build/package.json", '{"name":"fx"}')
put("images/y/Containerfile", table.concat({
    "FROM docker.io/library/node:22-bookworm-slim",
    'LABEL org.opencontainers.image.licenses="GPL-3.0-or-later"',
    "WORKDIR /opt/studio",
    "COPY package.json package-lock.json /opt/studio/",
    "RUN npm ci --ignore-scripts --omit=dev",
    "",
}, "\n"))
put("images/y/package-lock.json", lock("wrangler", "typescript"))
put("images/z/Containerfile", table.concat({
    "FROM docker.io/library/node:22-alpine",
    'LABEL org.opencontainers.image.licenses="GPL-3.0-or-later"',
    "COPY build/web ./build/web",
    "",
}, "\n"))
put("images/z/package-lock.json", lock("left-pad", "eslint"))
run({ "git", "init", "-q", DIR })

local r = run({ PLAN, "script", "run", "scripts/lua/build-stack-ledger.lua", "--", "--metadata", "meta.json", "--out", "out.json" }, { cwd = DIR })
local verdict_line = ""
for _, l in ipairs(text.lines(r.stdout or "")) do if l:match("^ok:") or l:match("^violation:") or l:match("^could%-not%-run:") or l:match("^refused:") then verdict_line = l end end
local out = fs.read(REL .. "/out.json")
local ledger = out and json.parse(out) or { nodes = {} }
local links = {}
for _, n in ipairs(ledger.nodes or {}) do links[n.id] = n.link end

local failed, arms = {}, 0
local function arm(n, name, ok, detail)
    arms = arms + 1
    if not ok then failed[#failed + 1] = string.format("arm %d (%s): %s", n, name, detail) end
    log.raw(string.format("  arm %d %s: %s", n, ok and "ok" or "FAILED", name))
end
local function got(id) return tostring(links[id] or "<absent>") end
arm(1, "builder-stage lockfile: shipped bundle is bundled-file; esbuild (executed by RUN, not a devDependency), @esbuild/* and the dev tool are build-stage-only",
    links["npm:react@1.0.0"] == "bundled-file" and links["npm:esbuild@3.0.0"] == "build-stage-only"
        and links["npm:@esbuild/linux-x64@3.0.0"] == "build-stage-only" and links["npm:typescript@2.0.0"] == "build-stage-only",
    "react=" .. got("npm:react@1.0.0") .. " esbuild=" .. got("npm:esbuild@3.0.0") .. " @esbuild/linux-x64=" .. got("npm:@esbuild/linux-x64@3.0.0")
        .. " typescript=" .. got("npm:typescript@2.0.0") .. " generator=" .. verdict_line)
arm(2, "final-stage npm ci --omit=dev: prod is container-image, dev is build-stage-only",
    links["npm:wrangler@1.0.0"] == "container-image" and links["npm:typescript@2.0.0"] == "build-stage-only",
    "wrangler=" .. got("npm:wrangler@1.0.0") .. " typescript=" .. got("npm:typescript@2.0.0"))
arm(3, "a lockfile no stage installs is link=unknown",
    links["npm:left-pad@1.0.0"] == "unknown" and links["npm:eslint@2.0.0"] == "unknown",
    "left-pad=" .. got("npm:left-pad@1.0.0"))
local found = 0
for _, id in ipairs({ "npm:react@1.0.0", "npm:wrangler@1.0.0", "npm:left-pad@1.0.0" }) do if links[id] then found = found + 1 end end
arm(4, "all three lockfiles were discovered, none named", found == 3, "discovered=" .. found .. "/3")

run({ "rm", "-rf", DIR })
if #failed > 0 then
    for _, f in ipairs(failed) do io.stdout:write(f .. "\n") end
    io.stdout:flush()
    verdict.emit("violation:stack-ledger-stages-fixture:" .. #failed, 1)
end
verdict.emit("ok:stack-ledger-stages-fixture:" .. arms, 0)
