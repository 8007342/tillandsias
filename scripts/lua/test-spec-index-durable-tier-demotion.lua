-- @env PATH HOME
-- @trace order:1087-h2z9, order:801-a2by, order:2386-zxgc
--
-- test-spec-index-durable-tier-demotion.lua — the spec-index resolver in spec-index-ensure.sh demotes
-- an unreadable volume by name, stays quiet on an absent one, and never falls back under target/.
-- Ported from the .sh of the same name (2386-zxgc). The resolution block is cut from the carrier; podman
-- is a stub that names the volume's mountpoint.
--
--   1 a reachable volume wins, with no reason    2 an unreadable one is a demotion, 3 naming the volume
--   4 an absent one falls through quietly        5 rung 4 is not under target/, 6 it is .cache/spec-index
--   7 the resolver emits root, serving and reason
--
-- Usage: tillandsias-plan script run scripts/lua/test-spec-index-durable-tier-demotion.lua
-- Verdict: ok:spec-index-durable-tier-demotion:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("spec-index-durable-tier-demotion")
local SH = fixture.posix_shell()
local src = "\n" .. fs.read("scripts/spec-index-ensure.sh"):gsub("\r", "")
local block = src:match("\n(# >>> BEGIN spec%-index resolution %(801%-a2by%).-\n# <<< END spec%-index resolution %(801%-a2by%)[^\n]*)")
if not block then T:refuse("markers-moved", "scripts/spec-index-ensure.sh") end
local w = T:scratch()
fs.write(w.rel .. "/block.sh", block .. "\n")
fs.mkdir(w.rel .. "/checkout/plan"); fs.write(w.rel .. "/checkout/plan/index.yaml", "")
fs.mkdir(w.rel .. "/bin"); fs.mkdir(w.rel .. "/goodvol"); fs.mkdir(w.rel .. "/denied/vol")
local CO = w.abs .. "/checkout"
local function resolve(podman_body)
    fs.write(w.rel .. "/bin/podman", "#!/bin/sh\n" .. podman_body .. "\n")
    T:must{ "chmod", "+x", w.abs .. "/bin/podman" }
    local r = T:run{ SH, "-s", "--", w.abs, CO, cwd = w.abs, timeout_ms = 30000, stdin = [==[
exec env -i HOME="$1/home" PATH="$1/bin:/usr/bin:/bin" TILLANDSIAS_SPEC_INDEX_CHECKOUT="$2" TILLANDSIAS_SPEC_INDEX_VOLUME=testvol \
    sh -c '. "$1/block.sh"; cd "$2" && _tillandsias_spec_index_paths' _ "$1" "$2"
]==] }
    local lines = {}
    for l in ((r.stdout or ""):gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
    if lines[#lines] == "" then lines[#lines] = nil end
    return { root = lines[1], reason = lines[3] or "", n = #lines, why = "rc=" .. tostring(r.code) .. " [" .. table.concat(lines, "|") .. "] " .. (r.stderr or ""):sub(1, 300) }
end
local x = resolve("echo '" .. w.abs .. "/goodvol'")
T:arm("1 a reachable volume wins rung 3, with no demotion", x.root == w.abs .. "/goodvol" and x.reason == "", x.why)
T:must{ "chmod", "000", w.abs .. "/denied" }
local hidden = T:run{ "test", "-e", w.abs .. "/denied/vol" }.code ~= 0
if not hidden then
    out.line("skip: 2 3 chmod 000 does not hide the child here (root, or msys); the not-permitted case cannot be built")
else
    x = resolve("echo '" .. w.abs .. "/denied/vol'")
    T:arm("2 an unreadable volume is a demotion, not an absence", x.reason ~= "" and x.root ~= w.abs .. "/denied/vol", x.why)
    T:arm("3 and the reason names the volume", x.reason:find("not%-permitted.*testvol") ~= nil, x.why)
end
T:must{ "chmod", "755", w.abs .. "/denied" }
x = resolve("exit 1")
T:arm("4 an absent volume falls through with no reason", x.reason == "", x.why)
-- Below the checkout: the scratch checkout itself lives under this repository's target/.
T:arm("5 rung 4 is not under the checkout's target/", x.root ~= nil and x.root:sub(1, #CO) == CO and not text.contains(x.root:sub(#CO + 1) .. "/", "/target/"), x.why)
T:arm("6 rung 4 is the checkout's .cache/spec-index", x.root == CO .. "/.cache/spec-index", x.why)
T:arm("7 the resolver emits root, serving and reason", x.n == 3, x.why)
T:finish()
