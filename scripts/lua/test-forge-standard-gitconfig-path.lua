-- @env PATH HOME XDG_RUNTIME_DIR TILLANDSIAS_FORGE_IMAGE TILLANDSIAS_GITCONFIG_FIXTURE_BOUND_SECS
-- @trace spec:git-mirror-service, order:800-ivkg, order:2368-efqj
--
-- test-forge-standard-gitconfig-path.lua — a forge reads its git config from the standard
-- ~/.gitconfig, bind-mounted read-only: safe.directory and the mirror redirect come from
-- that file, GIT_CONFIG_GLOBAL is unset, and a --global write fails. Ported from the .sh
-- (2368-efqj).
--
-- 800-ivkg: the container run is bounded BELOW the litmus step's budget, and on that bound
-- the fixture says SLOW, with the load and a timed podman info: a slow host must never
-- read as a config regression.
--
-- Verdict: ok:forge-standard-gitconfig-path:<n> arms
--        | violation:forge-standard-gitconfig-path:<n>-failed
--        | could-not-run:forge-standard-gitconfig-path:slow-host (exit 3)
--        | refused:forge-standard-gitconfig-path:no-forge-image

local fixture = require "common.fixture"
local forge = require "common.forge_image"
local T = fixture.new("forge-standard-gitconfig-path")
local bound = tonumber(env.get("TILLANDSIAS_GITCONFIG_FIXTURE_BOUND_SECS") or "") or 25
local t0 = time.now_ms()
local IMAGE = forge.pick(T)
if not IMAGE then T:refuse("no-forge-image", "no tillandsias-forge image available (need one build first)") end
local t1 = time.now_ms()
local W = T:scratch()
fs.write(W.rel .. "/gitconfig", '[safe]\n\tdirectory = /home/forge/src/*\n[credential]\n\thelper = \n[url "git://tillandsias-git/"]\n\tinsteadOf = https://github.com/example/\n')
local r = forge.run(T, IMAGE, { "--mount", "type=bind,source=" .. W.abs .. "/gitconfig,target=/home/forge/.gitconfig,readonly=true" }, [[
echo "global=${GIT_CONFIG_GLOBAL:-}"
echo "safe=$(git config --global --show-origin --get safe.directory)"
echo "redirect=$(git config --global --show-origin --get-regexp '^url\..*\.insteadof$')"
if git config --global user.name forge-write-must-fail 2>/dev/null; then echo "write=accepted"; else echo "write=refused"; fi
]], math.floor(bound * 1000))
local t2 = time.now_ms()
local l = T:run{ "cat", "/proc/loadavg" }
local load = text.trim(l.stdout or ""):match("^%S+ %S+ %S+") or "unknown"
out.line("timing: image_lookup_ms=" .. (t1 - t0) .. " container_ms=" .. (t2 - t1) .. " loadavg=[" .. load .. "]")
if r.status == "timeout" or r.status == "timed_out" then
    local p0 = time.now_ms()
    local p = T:run{ "podman", "info", timeout_ms = 60000 }
    out.line("SLOW: the forge container did not finish within " .. bound .. "s — a HOST condition, not a gitconfig regression: loadavg=[" .. load
        .. "], podman info took " .. (time.now_ms() - p0) .. "ms (" .. tostring(p.status) .. "). Re-run on a quieter host (800-ivkg).")
    T:cleanup()
    verdict.emit("could-not-run:forge-standard-gitconfig-path:slow-host", 3)
end
local f = {}
for k, v in (r.stdout or ""):gmatch("(%w+)=([^\n]*)\n") do f[k] = v end
local raw = "status=" .. tostring(r.status) .. " rc=" .. tostring(r.code) .. " " .. ((r.stdout or "") .. (r.stderr or "")):gsub("\n", " | ")
T:arm("GIT_CONFIG_GLOBAL is unset in the forge", f.global == "", raw)
T:arm("safe.directory comes from ~/.gitconfig", f.safe == "file:/home/forge/.gitconfig\t/home/forge/src/*", raw)
T:arm("the mirror redirect comes from ~/.gitconfig", (f.redirect or ""):find("^file:/home/forge/%.gitconfig\t.*https://github%.com/example/$"), raw)
T:arm("the mounted global config is not writable", f.write == "refused", raw)
T:finish()
