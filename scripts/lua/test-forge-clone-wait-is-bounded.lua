-- @trace order:777-k88g, order:777-i7hf, order:2312-d2gf, spec:git-mirror-service
--
-- test-forge-clone-wait-is-bounded.lua — the forge clone gives up, says why, and
-- does not return quietly. Ported from the .sh (2312-d2gf).
--
-- litmus:forge-clone-reachability-probe-shape greps the loop's SOURCE line. This
-- pins the BEHAVIOUR: a loop can be bounded in source and still return 0 on
-- exhaustion, and bounded-loud-and-quietly-successful is what no grep sees. The
-- FATAL text and the status come from different statements, so each has an arm.
--
-- Hermetic and offline: the function is cut from images/default/lib-common.sh and
-- every external is a stub (git clone's status is the knob; sleep is a no-op).
--
--   1 the clone gives up instead of retrying forever
--   2 exhaustion leaves a NON-ZERO status for the lane
--   3 exhaustion writes a FATAL naming the mirror
--   4 NEGATIVE CONTROL a clone that succeeds reports no FATAL
--
-- Verdict: ok:forge-clone-wait-is-bounded:4 | violation:forge-clone-wait-is-bounded:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("forge-clone-wait-is-bounded")
local W = T:scratch()

local impl, on = {}, false
for _, l in ipairs(text.lines(fs.read("images/default/lib-common.sh"))) do
    if l:find("^_clone_project_from_mirror_impl%(%) {") then on = true end
    if on then
        impl[#impl + 1] = l
        if l:sub(1, 1) == "}" then break end
    end
end
local src = table.concat(impl, "\n")
-- The premise keys on the exhaustion FATAL, never on the loop literal: an
-- unbounded loop (what arm 1 catches) must not remove the anchor.
if not src:find("FATAL: git clone failed", 1, true) then
    T:refuse("no-subject", "no _clone_project_from_mirror_impl with a clone-failure FATAL in images/default/lib-common.sh")
end
fs.write(W.rel .. "/impl.sh", [[
set -uo pipefail
git_mirror_host() { printf 'test-mirror-host'; }
trace_lifecycle() { :; }
checkout_forge_seed_branch() { :; }
rewrite_origin_for_enclave_push() { :; }
probe_mirror_reachable() { return 0; }
# 1310-rec6 step 4 added this call to the impl; unstubbed it exits 127.
forge_mirror_relay_gate() { return 0; }
export_ssh_env() { :; }
sleep() { :; }
CLONE_RC="$1"
git() { case "$1" in clone) return "$CLONE_RC" ;; *) return 0 ;; esac; }
TILLANDSIAS_GIT_SERVICE=1
TILLANDSIAS_PROJECT=testproj
TILLANDSIAS_GIT_MIRROR_PATH=
]] .. src .. '\n_clone_project_from_mirror_impl "$2"\n')

local function run(clone_rc)
    local r = T:run{ fixture.posix_shell(), W.abs .. "/impl.sh", clone_rc, W.abs .. "/clone-" .. clone_rc,
        cwd = W.abs, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    return r, (r.stdout or "") .. (r.stderr or "")
end

local r, said = run("1")
T:arm("1 the clone gives up instead of retrying forever", r.code ~= nil, "still running at 60 s: " .. tostring(r.status))
T:arm("2 exhaustion leaves a NON-ZERO status for the lane", r.code ~= nil and r.code ~= 0, "rc=" .. tostring(r.code))
T:arm("3 exhaustion writes a FATAL naming the mirror", said:find("FATAL.*mirror") ~= nil or said:find("FATAL.*clone") ~= nil, said)

local k, good = run("0")
T:arm("4 NEGATIVE CONTROL a successful clone reports no FATAL", k.code ~= nil and not good:find("FATAL", 1, true), "rc=" .. tostring(k.code) .. " " .. good)
T:finish({ ok = function(n) return "ok:forge-clone-wait-is-bounded:" .. n end })
