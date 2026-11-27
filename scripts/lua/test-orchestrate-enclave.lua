-- @env PATH
-- @trace order:1170-e5im, order:2379-p5dq
--
-- test-orchestrate-enclave.lua — scripts/orchestrate-enclave.sh Step 5 launches the forge whether or not
-- TILLANDSIAS_STATUS_CHECK is set; the probe and the two Step 4 refinements that guard is for still happen
-- only with it. The script runs in a scratch tree with its real siblings and an `env -i`, and every command
-- it reaches (podman, openssl, tillandsias, nvidia-smi) is a stub that logs its argv.
-- Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/test-orchestrate-enclave.lua
-- Verdict: ok:orchestrate-enclave:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("orchestrate-enclave")
local SH = fixture.posix_shell()
local src = "\n" .. fs.read("scripts/orchestrate-enclave.sh"):gsub("\r\n", "\n")

-- A stub logs its argv beside its bin dir, one call per line.
local LOG = '#!/usr/bin/env bash\n{ printf \'%s\' "${0##*/}"; printf \' %q\' "$@"; printf \'\\n\'; } >> "${0%/*}/../calls.log"\n'
local PODMAN = LOG .. [[
case "$1" in
    images) printf 'localhost/tillandsias-%s:v0.0.0-orchtest\n' proxy git inference ;;
    network) case "$2" in exists) exit 1 ;; inspect) echo true ;; esac ;;
esac
exit 0
]]
local OPENSSL = LOG .. 'p=""; for a in "$@"; do case "$p" in -keyout|-out) : > "$a" ;; esac; p="$a"; done\nexit 0\n'
local function orchestrate(tag, body, status_check)
    local d = T:scratch(tag)
    for _, s in ipairs{ "scripts", "scripts/lib", "bin", "home", "tmp", "project" } do fs.mkdir(d.rel .. "/" .. s) end
    for _, f in ipairs{ "common.sh", "lib-ca-path.sh", "lib/enclave-proxy.sh", "lib/tool-dispatch.sh", "nvidia-cdi-ensure.sh" } do
        fs.write(d.rel .. "/scripts/" .. f, (fs.read("scripts/" .. f):gsub("\r\n", "\n")))
    end
    fs.write(d.rel .. "/scripts/orchestrate-enclave.sh", body:sub(2))
    fs.write(d.rel .. "/VERSION", "0.0.0-orchtest\n")
    fs.write(d.rel .. "/project/README", "harmless\n")
    fs.write(d.rel .. "/calls.log", "")
    fs.write(d.rel .. "/bin/podman", PODMAN)
    fs.write(d.rel .. "/bin/openssl", OPENSSL)
    -- Step 4 greps this answer under set -e: an empty one would end the script before Step 5.
    fs.write(d.rel .. "/bin/tillandsias", LOG .. "echo '{\"legacy_tier\": \"cpu\"}'\n")
    fs.write(d.rel .. "/bin/nvidia-smi", LOG)
    local r = T:run{ SH, "-s", "--", d.abs, status_check, env = { PATH = env.get("PATH") }, timeout_ms = 120000, stdin = [[
cd "$1" || exit 96; r="$PWD"
chmod +x bin/* scripts/*.sh
env -i PATH="$r/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$r/home" TMPDIR="$r/tmp" TILLANDSIAS_CA_DIR="$r/ca" TILLANDSIAS_STATUS_CHECK="$2" \
    "$BASH" scripts/orchestrate-enclave.sh "$r/project" orchtest </dev/null
]] }
    local calls = fs.read(d.rel .. "/calls.log")
    local function reached(s) return text.contains(calls, s) end
    return { forge = reached("run --interactive --tty --rm --name tillandsias-orchtest-forge"), probe = reached("--entrypoint /bin/bash"),
        pulls = reached("TILLANDSIAS_INFERENCE_SKIP_RUNTIME_PULLS=1"), wait = reached("wait --condition=healthy tillandsias-inference"),
        code = r.code, network = reached("podman network"), got = "rc=" .. tostring(r.code) .. " " .. (r.stderr or ""):sub(-300) .. " calls: " .. calls:sub(-300) }
end
local x = orchestrate("unset", src, "")
T:arm("1 with no status check the forge is launched", x.forge and x.code == 0, x.got)
T:arm("1 and nothing the status check is for happens", not x.probe and not x.pulls and not x.wait, x.got)
x = orchestrate("set", src, "1")
T:arm("2 with it, the probe, the skipped pulls and the health wait all happen", x.probe and x.pulls and x.wait, x.got)
T:arm("2 and the forge is launched too", x.forge, x.got)

local BEGIN, END = "\n# forge-launch-unconditional-begin\n", "\n# forge-launch-unconditional-end\n"
local a, b = src:find(BEGIN, 1, true)
local c, e = src:find(END, 1, true)
if not a or not c or c < b then T:refuse("mutation-anchor-missing", "the forge-launch-unconditional markers") end
x = orchestrate("renested", src:sub(1, b) .. 'if [ -n "$STATUS_CHECK_MODE" ]; then\n' .. src:sub(b + 1, c) .. "fi" .. src:sub(c, e) .. src:sub(e + 1), "")
T:arm("3 MUTATION the launch put back under the guard fails arm 1", not x.forge and x.network and x.code == 0, x.got)
local p, q = src:find('if [ -n "$STATUS_CHECK_MODE" ]; then', 1, true)
if not p then T:refuse("mutation-anchor-missing", "the Step 4 guard") end
x = orchestrate("unguarded", src:sub(1, p - 1) .. "if true; then" .. src:sub(q + 1), "")
T:arm("3 MUTATION a Step 4 refinement let out of its guard fails arm 1", x.forge and (x.pulls or x.wait or x.probe), x.got)

T:finish()
