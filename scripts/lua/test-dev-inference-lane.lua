-- @trace order:1249-xngp
-- @env HOME PATH
--
-- test-dev-inference-lane.lua — scripts/dev-inference-ensure.sh names the lane
-- that SERVED, on every lane (1249-xngp), with stub `curl` and `podman` on a
-- scratch PATH. The stubs keep their state in files: up-<port> means an
-- engine answers that port, container-<name> holds a container's status.
--   1 CONTAINER   linux-container, tillandsias-dev-inference running and
--                 answering: ok:dev-inference-ready:…:lane=container
--   2 BARE-METAL  linux-container, the port answers but the container is not
--                 running (a host-native engine holds it): lane=bare-metal.
--                 Before 1249-xngp both read `ok:dev-inference-ready:g:e`.
--   3 NEGATIVE    linux-container with NO engine anywhere: the fallback starts
--                 and says so, ok:dev-inference-started:…:lane=container (the
--                 preference never becomes a requirement)
--   4 MACOS-UP    macos-native, a host-native engine answers: lane=bare-metal
--   5 MACOS-DOWN  macos-native, nothing answers: blocked:no-engine:macos-native,
--                 exit 1, with the remedy (was skip:unsupported-host)
--   6 PROBE       --probe-fallback on linux-container while a bare-metal engine
--                 serves 11434: the probe container comes up on 11435, reports
--                 ok:fallback-healthy:container:port=11435, is removed, and the
--                 serving engine is never touched
--   7 PROBE-SKIP  --probe-fallback on macos-native: skip:no-container-fallback
--
-- Usage: tillandsias-plan script run scripts/lua/test-dev-inference-lane.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("dev-inference-lane", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/dev-inference-lane-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)
local ABS = ROOT .. "/" .. REL

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name .. (got and (" — " .. got) or "")) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

-- curl: answers http://127.0.0.1:<port>/api/version and /api/tags when
-- $STUB/up-<port> exists; any other URL fails (no network in this fixture).
local CURL = [[#!/bin/bash
url=""
for a in "$@"; do case "$a" in http://*|https://*) url="$a" ;; esac; done
port="$(printf '%s' "$url" | sed -nE 's#^http://127\.0\.0\.1:([0-9]+)/.*#\1#p')"
[ -n "$port" ] && [ -f "$STUB/up-$port" ] || exit 7
case "$url" in
  */api/version) echo '{"version":"0.0.0-stub"}' ;;
  */api/tags) echo '{"models":[{"name":"qwen2.5:0.5b"},{"name":"nomic-embed-text:latest"}]}' ;;
  *) exit 22 ;;
esac
]]
-- podman: container state in $STUB/container-<name>; `run --publish
-- 127.0.0.1:<port>:11434` brings that port up; `rm -f` takes it down.
local PODMAN = [[#!/bin/bash
echo "podman $*" >> "$STUB/podman.log"
case "$1" in
  container) [ "$2" = exists ] && [ -f "$STUB/container-$3" ]; exit $? ;;
  inspect) n="${!#}"; [ -f "$STUB/container-$n" ] && cat "$STUB/container-$n" || exit 125 ;;
  images) echo "localhost/tillandsias-inference:v1" ;;
  start) echo running > "$STUB/container-$2" ;;
  run)
    name=""; port=""; prev=""
    for a in "$@"; do
      case "$prev" in --name) name="$a" ;; --publish) port="$(printf '%s' "$a" | cut -d: -f2)" ;; esac
      prev="$a"
    done
    echo running > "$STUB/container-$name"
    [ -n "$port" ] && : > "$STUB/up-$port"
    echo "port-$port" > "$STUB/port-of-$name" ;;
  rm)
    name="${!#}"
    if [ -f "$STUB/port-of-$name" ]; then p="$(sed 's/port-//' "$STUB/port-of-$name")"; rm -f "$STUB/up-$p" "$STUB/port-of-$name"; fi
    rm -f "$STUB/container-$name" ;;
esac
exit 0
]]

-- tillandsias: on a host where the product is installed (the Linux gate),
-- ensure_container asks `tillandsias --capabilities`, whose accelerator probe
-- looks INSIDE the container named by TILLANDSIAS_INFERENCE_CONTAINER (967-6ax6).
-- This stub does the same, so every host runs that path, not only the ones
-- with the product installed (the Linux gate caught arm 6 that darwin missed).
local TILLANDSIAS = [[#!/bin/bash
[ "$1" = --capabilities ] || exit 0
podman exec "${TILLANDSIAS_INFERENCE_CONTAINER:-tillandsias-inference}" ls /dev/dri >/dev/null 2>&1
echo '{"legacy_tier":"cpu"}'
]]

local function case_dir(name)
    local d = REL .. "/" .. name
    fs.mkdir(d .. "/bin")
    fs.mkdir(d .. "/stub")
    fs.mkdir(d .. "/home")
    fs.write(d .. "/bin/curl", CURL)
    fs.write(d .. "/bin/podman", PODMAN)
    fs.write(d .. "/bin/tillandsias", TILLANDSIAS)
    proc.run({ argv = { "chmod", "+x", ABS .. "/" .. name .. "/bin/curl", ABS .. "/" .. name .. "/bin/podman",
        ABS .. "/" .. name .. "/bin/tillandsias" }, timeout_ms = 10000 })
    return d, ABS .. "/" .. name
end
local function run_ensure(abs, lane, extra_arg)
    local argv = { "bash", ROOT .. "/scripts/dev-inference-ensure.sh" }
    if extra_arg then argv[#argv + 1] = extra_arg end
    local r = proc.run({ argv = argv, cwd = ROOT, timeout_ms = 60000, env = {
        PATH = abs .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin"),
        HOME = abs .. "/home",
        STUB = abs .. "/stub",
        TILLANDSIAS_DEV_INFERENCE_LANE_OVERRIDE = lane,
        TILLANDSIAS_DEV_INFERENCE_HOME = abs .. "/state",
        TILLANDSIAS_DEV_INFERENCE_READY_SECS = "4",
        TILLANDSIAS_DEV_INFERENCE_PORT = "11434",
    } })
    return r.code or -1, text.trim(r.stdout or ""), text.trim(r.stderr or "")
end
local OKREADY = "ok:dev-inference-ready:qwen2.5:0.5b:nomic-embed-text:lane="
local OKSTART = "ok:dev-inference-started:qwen2.5:0.5b:nomic-embed-text:lane="

-- 1 CONTAINER
local d, a = case_dir("container")
fs.write(d .. "/stub/up-11434", "")
fs.write(d .. "/stub/container-tillandsias-dev-inference", "running\n")
local rc, o = run_ensure(a, "linux-container")
arm("1 CONTAINER the running dev container is named as the serving lane", rc == 0 and o == OKREADY .. "container", rc .. " " .. o)

-- 2 BARE-METAL
d, a = case_dir("baremetal")
fs.write(d .. "/stub/up-11434", "")
rc, o = run_ensure(a, "linux-container")
arm("2 BARE-METAL a host-native engine on the port is named, not taken for the container", rc == 0 and o == OKREADY .. "bare-metal", rc .. " " .. o)

-- 3 NEGATIVE CONTROL
d, a = case_dir("negative")
rc, o = run_ensure(a, "linux-container")
arm("3 NEGATIVE with no engine anywhere the container fallback starts and says so",
    rc == 0 and o == OKSTART .. "container", rc .. " " .. o)

-- 4 MACOS-UP
d, a = case_dir("macup")
fs.write(d .. "/stub/up-11434", "")
rc, o = run_ensure(a, "macos-native")
arm("4 MACOS-UP a host-native engine on macOS is the bare-metal lane", rc == 0 and o == OKREADY .. "bare-metal", rc .. " " .. o)

-- 5 MACOS-DOWN
d, a = case_dir("macdown")
local e
rc, o, e = run_ensure(a, "macos-native")
arm("5 MACOS-DOWN no engine on macOS is refused with the remedy",
    rc == 1 and o == "blocked:no-engine:macos-native" and e:find("ollama serve", 1, true) ~= nil, rc .. " " .. o)

-- 6 PROBE
d, a = case_dir("probe")
fs.write(d .. "/stub/up-11434", "")
rc, o = run_ensure(a, "linux-container", "--probe-fallback")
local plog = fs.exists(d .. "/stub/podman.log") and fs.read(d .. "/stub/podman.log") or ""
arm("6 PROBE the fallback is probed on 11435 and removed, the serving engine untouched",
    rc == 0 and o == "ok:fallback-healthy:container:port=11435"
    and plog:find("--name tillandsias-dev-inference-probe", 1, true) ~= nil
    and plog:find("127.0.0.1:11435:11434", 1, true) ~= nil
    and not fs.exists(d .. "/stub/container-tillandsias-dev-inference-probe")
    and fs.exists(d .. "/stub/up-11434")
    and plog:find("tillandsias-dev-inference ", 1, true) == nil, rc .. " " .. o .. " podman.log=[" .. plog .. "]")

-- 7 PROBE-SKIP
d, a = case_dir("probeskip")
rc, o = run_ensure(a, "macos-native", "--probe-fallback")
arm("7 PROBE-SKIP macOS has no container fallback to probe", rc == 0 and o == "skip:no-container-fallback:macos-native", rc .. " " .. o)

proc.run({ argv = { "rm", "-rf", ABS }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:dev-inference-lane:" .. #failed .. "-failed", 1)
end
verdict.ok("dev-inference-lane", "7 arms")
