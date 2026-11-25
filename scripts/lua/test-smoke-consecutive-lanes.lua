-- @trace order:767-qrbv, spec:meta-orchestration
--
-- test-smoke-consecutive-lanes.lua — scripts/smoke-consecutive-lanes.sh, with a
-- stub lane launcher and a stub podman driving every verdict. Ported from the .sh.
--   1 both lanes green, stack kept -> ok:…:stack=kept, rc 0
--   2 lane 1 fails                 -> lane1-failed, lane 2 NOT launched
--   3 lane 2 fails                 -> lane2-failed
--   4 lane 2 exits 0 but its log carries the supervisor's crash verdict
--                                  -> lane2-harness-crashed (rc 0 is not health)
--   5 lane 2 replaces a stack container -> stack-replaced
--   6 no shared stack container    -> no-stack
--   7 lane 2 has its own forge     -> still ok (new; the .sh could not see it)
-- Every fail: verdict exits 1.
--
-- Verdict: ok:smoke-consecutive-lanes:<n> | violation:smoke-consecutive-lanes:<n>

local fixture = require "common.fixture"
local T = fixture.new("smoke-consecutive-lanes")
local SH = fixture.posix_shell()
local W = T:scratch()
fs.mkdir(W.rel .. "/bin"); fs.mkdir(W.rel .. "/root/scripts")
fs.write(W.rel .. "/root/scripts/smoke-consecutive-lanes.sh", fs.read("scripts/smoke-consecutive-lanes.sh"))
fs.write(W.rel .. "/bin/podman", '#!/usr/bin/env bash\ncat "$STUB_DIR/containers"\n')
fs.write(W.rel .. "/launcher.sh", [[
#!/usr/bin/env bash
# lane n = lines in $STUB_DIR/launched; plan line n: "<rc> <log-text> [name=newid]"
echo x >> "$STUB_DIR/launched"
n="$(wc -l < "$STUB_DIR/launched" | tr -d ' ')"
read -r rc text newid <<< "$(sed -n "${n}p" "$STUB_DIR/plan")"
printf '%s\n' "$text" > "$STUB_DIR/lane.log"
if [ -n "$newid" ]; then
    sed "s/^${newid%%=*}=.*/$newid/" "$STUB_DIR/containers" > "$STUB_DIR/containers.tmp" \
        && mv "$STUB_DIR/containers.tmp" "$STUB_DIR/containers" || exit 97
fi
exit "$rc"
]])
-- PATH is set here, from the script's own directory: msys prepends its dirs to
-- an inherited PATH, and a C:/ root splits it at the drive.
fs.write(W.rel .. "/go.sh", [[
D="$(cd "$(dirname "$0")" && pwd)"
export STUB_DIR="$D/c-$1" PATH="$D/bin:$PATH"
export TILLANDSIAS_CONSECUTIVE_LAUNCHER="$D/launcher.sh" TILLANDSIAS_CONSECUTIVE_LANE_LOG="$STUB_DIR/lane.log"
cd "$D/root" && bash scripts/smoke-consecutive-lanes.sh --gap 0 2>/dev/null
]])
T:must{ "chmod", "+x", W.abs .. "/bin/podman", W.abs .. "/launcher.sh" }

local function run(name, containers, lane1, lane2)
    local d = W.rel .. "/c-" .. name
    fs.mkdir(d)
    fs.write(d .. "/containers", containers)
    fs.write(d .. "/plan", lane1 .. "\n" .. lane2 .. "\n")
    fs.write(d .. "/launched", "")
    local r = T:run{ SH, W.abs .. "/go.sh", name, timeout_ms = 30000 }
    local lines = text.lines(text.trim(r.stdout or ""))
    local _, launched = fs.read(d .. "/launched"):gsub("x", "")
    return lines[#lines] or "", r.code, launched, fs.read(d .. "/containers")
end
local function is(v, p) return v:sub(1, #p) == p end
local STACK = "tillandsias-proxy=aaa\ntillandsias-vault=bbb\ntillandsias-git-alpha=ccc\ntillandsias-alpha-forge=zzz\n"
local PASS = "0 MO-SMOKE:PASS"
local function got(v, rc, n) return "[" .. v .. "] rc=" .. tostring(rc) .. " launched=" .. n end

local v, rc, n, c = run("green", STACK, PASS, PASS)
T:arm("1 GREEN two green lanes on the same stack", v == "ok:consecutive-lanes:lane1=0:lane2=0:gap=0:stack=kept" and rc == 0 and n == 2, got(v, rc, n))
v, rc, n = run("l1", STACK, "1 boom", PASS)
T:arm("2 LANE1 a failed lane 1 stops before lane 2", is(v, "fail:consecutive-lanes:lane1-failed:lane1=1:lane2=not-run:") and rc == 1 and n == 1, got(v, rc, n))
v, rc, n = run("l2", STACK, PASS, "126 no-verdict")
T:arm("3 LANE2 a failed lane 2 is named with its code", is(v, "fail:consecutive-lanes:lane2-failed:lane1=0:lane2=126:") and rc == 1 and n == 2, got(v, rc, n))
v, rc, n = run("crash", STACK, PASS, "0 fail:harness-crashed:harness=opencode:signal=11:rc=139")
T:arm("4 CRASH a crash verdict under rc 0 is caught", is(v, "fail:consecutive-lanes:lane2-harness-crashed:") and rc == 1 and n == 2, got(v, rc, n))
v, rc, n, c = run("replaced", STACK, PASS, "0 MO-SMOKE:PASS tillandsias-proxy=NEWID")
T:arm("5 REPLACED only the proxy's id changed, and it is caught", is(v, "fail:consecutive-lanes:stack-replaced:") and rc == 1
    and c == STACK:gsub("proxy=aaa", "proxy=NEWID"), got(v, rc, n) .. " " .. c)
v, rc, n = run("nostack", "ollama=111\ntillandsias-builder=222\n", PASS, PASS)
T:arm("6 NO-STACK no shared stack container stops before lane 2", is(v, "fail:consecutive-lanes:no-stack:") and rc == 1 and n == 1, got(v, rc, n))
v, rc, n = run("forge", STACK, PASS, "0 MO-SMOKE:PASS tillandsias-alpha-forge=NEWID")
T:arm("7 FORGE a new forge container is not a replaced stack (each lane has its own)", is(v, "ok:consecutive-lanes:") and rc == 0, got(v, rc, n))
T:finish()
