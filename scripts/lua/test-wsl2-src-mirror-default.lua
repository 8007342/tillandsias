-- @trace order:1924-gyff, order:667-kfyn
-- @env PATH
--
-- test-wsl2-src-mirror-default.lua — order 1924-gyff.
--
-- On Windows the gate and the preflight read the tree from a distro-native
-- ext4 copy by default, not over 9p from /mnt/c. Measured on yolanda
-- 2026-10-29: test-trace-coverage 176 s from /mnt/c, 1.5 s from ext4.
--
-- The decision is with-wsl2-builder.sh's own _w2_src_mirror_wanted function,
-- cut out of the file and RUN, so the arms exercise the subject itself.
--
--   1 --preflight, no env: mirror
--   2 --check and --test, no env: mirror
--   3 TILLANDSIAS_WSL2_SRC_MIRROR=0 opts out: in-tree
--   4 TILLANDSIAS_WSL2_SRC_IN_TREE=1 forces in-tree
--   5 a building mode (--ci-full --install) and a non-build.sh script: in-tree
--   6 the wrapper decides through the function, and the sync runs only on mirror
--
-- Pre-fix result: FAILS, there is no such function, and --preflight built
-- in-tree even with TILLANDSIAS_WSL2_SRC_MIRROR=1.
--
-- Usage: tillandsias-plan script run scripts/lua/test-wsl2-src-mirror-default.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("wsl2-src-mirror-default", "git rev-parse --show-toplevel did not answer")
end
local W = ROOT .. "/scripts/with-wsl2-builder.sh"
local src = fs.exists(W) and fs.read(W) or ""

-- The function's own text, from its definition line to its closing brace.
local fn = src:match("\n(_w2_src_mirror_wanted%(%) {\n.-\n}\n)")
if not fn then
    verdict.emit("violation:wsl2-src-mirror-default:no-function", 1,
        "with-wsl2-builder.sh defines no _w2_src_mirror_wanted (1924-gyff)")
end

local failed = {}
local function arm(name, cond, got)
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end
-- decide(env_prefix, script, args...) -> what the function prints
local function decide(env, script, ...)
    local call = "_w2_src_mirror_wanted " .. script
    for _, a in ipairs({ ... }) do call = call .. " " .. a end
    local r = proc.run({
        argv = { "env", "-u", "TILLANDSIAS_WSL2_SRC_MIRROR", "-u", "TILLANDSIAS_WSL2_SRC_IN_TREE",
                 "bash", "-c", env .. fn .. "\n" .. call },
        timeout_ms = 10000,
    })
    return text.trim(r.stdout or "") .. (r.code ~= 0 and (" rc=" .. tostring(r.code)) or "")
end

local d = decide("", "build.sh", "--preflight")
arm("1 --preflight takes the ext4 mirror by default", d == "mirror", d)
local c, t = decide("", "build.sh", "--check"), decide("", "build.sh", "--test")
arm("2 --check and --test take the mirror by default", c == "mirror" and t == "mirror", c .. "/" .. t)
d = decide("TILLANDSIAS_WSL2_SRC_MIRROR=0\n", "build.sh", "--preflight")
arm("3 TILLANDSIAS_WSL2_SRC_MIRROR=0 opts out", d == "in-tree", d)
d = decide("TILLANDSIAS_WSL2_SRC_IN_TREE=1\n", "build.sh", "--check")
arm("4 TILLANDSIAS_WSL2_SRC_IN_TREE=1 forces in-tree", d == "in-tree", d)
local b, o = decide("", "build.sh", "--ci-full", "--install"), decide("", "local-ci.sh", "--check")
arm("5 a building mode and another script stay in-tree", b == "in-tree" and o == "in-tree", b .. "/" .. o)

-- 6: comments do not count; the call and the sync guard must be code.
local code = {}
for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    if not line:match("^%s*#") then code[#code + 1] = line end
end
code = table.concat(code, "\n")
arm("6 the wrapper decides through the function and syncs only on mirror",
    code:find('if [[ "$(_w2_src_mirror_wanted "$(basename "$SCRIPT_REL")" "$@")" == mirror ]]; then', 1, true) ~= nil
    and code:find('if [[ "$_w2_mirror" == 1 ]]; then\n    _w2_src_linux=', 1, true) ~= nil,
    "call site or sync guard missing")

if #failed > 0 then
    verdict.emit("violation:wsl2-src-mirror-default:" .. #failed .. "-failed", 1)
end
verdict.ok("wsl2-src-mirror-default", "6 arms")
