-- @env PATH HOME XDG_RUNTIME_DIR
-- @trace spec:forge-as-only-runtime, order:2349-9vaq, order:459, order:2027-e2cf
--
-- test-forge-image-agents.lua — the forge image holds bash, and for each of claude, codex and
-- opencode the lane that installs it at launch. Each name is asked alone: the check this replaces
-- ran `command -v claude codex opencode bash`, and bash's command -v exits 0 when ANY name is
-- found, so it was green on an image with none of the three.
--
-- A lane is present when entrypoint-forge-<agent>.sh calls require_<agent> and lib-common.sh
-- defines it. Needs a local forge image and runs no network; skips by name without one.
--
--   1 bash                     2-4 the claude, codex and opencode lanes
--   5 RED a lib-common.sh without the installers fails all three
--   6 RED an entrypoint without its call fails its own lane and no other
--   7 RED an image with no bash on PATH fails 1
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-image-agents.lua
-- Verdict: ok:forge-image-agents:<n> arms | violation:... | skip:forge-image-agents:no-forge-image

local fixture = require "common.fixture"
local T = fixture.new("forge-image-agents")
local E = { PATH = env.get("PATH"), HOME = env.get("HOME"), XDG_RUNTIME_DIR = env.get("XDG_RUNTIME_DIR") }
local function podman(...)
    return proc.run{ argv = { "podman", ... }, env = E, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
end
local imgs = podman("images", "--format", "{{.Repository}}:{{.Tag}}")
-- A podman that does not answer is not an absent image.
if imgs.code ~= 0 then T:refuse("podman-did-not-answer", "rc=" .. tostring(imgs.code) .. " " .. (imgs.stderr or "")) end
local IMG = ("\n" .. (imgs.stdout or "")):match("\n(localhost/tillandsias%-forge:v[^\n]*)")
if not IMG then T:skip("no-forge-image") end
out.line("image: " .. IMG)

local LIB, BIN = "/usr/local/lib/tillandsias/lib-common.sh", "/usr/local/bin/entrypoint-forge-"
local ASK = 'if command -v bash >/dev/null 2>&1; then echo bash=yes; fi\nfor a in claude codex opencode; do\n'
    .. '  if grep -qE "^ *require_$a( |\\$)" ' .. BIN .. '$a.sh && grep -qE "^require_$a\\(\\) \\{" ' .. LIB .. '; then echo "$a=yes"; fi\ndone\necho asked\n'
-- opts: extra `podman run` arguments. Returns what the image answered, name -> true.
local function ask(...)
    local argv = { "run", "--rm", "--network", "none", ... }
    for _, a in ipairs{ "--entrypoint", "/bin/sh", IMG, "-c", ASK } do argv[#argv + 1] = a end
    local r = podman(table.unpack(argv))
    local has, o = {}, (r.stdout or "")
    for n in o:gmatch("(%a+)=yes") do has[n] = true end
    has.asked = r.code == 0 and text.contains(o, "asked")
    has.why = "rc=" .. tostring(r.code) .. " " .. o .. (r.stderr or "")
    return has
end
local x = ask()
T:arm("1 bash is on PATH", x.asked and x.bash, x.why)
for i, a in ipairs{ "claude", "codex", "opencode" } do
    T:arm((i + 1) .. " the " .. a .. " lane installs its agent at launch", x.asked and x[a], x.why)
end
local d = T:scratch()
fs.write(d.rel .. "/empty", "# no installers here\n")
local function over(path) return "-v", d.abs .. "/empty:" .. path .. ":ro,z" end
x = ask(over(LIB))
T:arm("5 RED without the installers all three lanes fail", x.asked and x.bash and not (x.claude or x.codex or x.opencode), x.why)
x = ask(over(BIN .. "codex.sh"))
T:arm("6 RED without its call the codex lane fails and no other", x.asked and not x.codex and x.claude and x.opencode, x.why)
x = ask("-e", "PATH=/nowhere")
T:arm("7 RED with no bash on PATH arm 1 fails", not x.bash, x.why)
T:finish()
