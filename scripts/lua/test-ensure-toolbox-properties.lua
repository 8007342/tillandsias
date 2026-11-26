-- @env PATH
-- @trace spec:dev-build, order:777-amku, order:634-39ik, order:2373-f26m
--
-- test-ensure-toolbox-properties.lua — the toolbox-first include's PROPERTIES, not its
-- source text: an ensure_toolbox.sh that did nothing passed every shape check on this host.
-- Each property is a predicate run twice: it must HOLD for the real include and FAIL for a
-- mutant with exactly that property removed. A mutation that changes nothing refuses: a
-- control that removes nothing certifies everything. Ported from the .sh (2373-f26m).
--
--   P1 a missing toolbox is created and initialised   P2 a second run does nothing
--   P3 a host with no toolbox: rc 0, BOTH streams empty
--   P4 a FAILED ensure is loud                        P5 it delegates, duplicating nothing
-- Hermetic: a fake `toolbox` and `rpm-ostree` first on PATH, a scratch HOME, and a container
-- name of its own; a real toolbox reached would leave the call log empty and everything red.
-- P1, P2, P4 and P5 need /etc/os-release (the delegate's Silverblue guard reads it).
-- Not under test: whether a real `toolbox create` succeeds (the daily build lane).
--
-- Verdict: ok:ensure-toolbox-properties:<n> arms | violation:ensure-toolbox-properties:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("ensure-toolbox-properties")
local SH = fixture.posix_shell()
local INCLUDE, DELEGATE = "ensure_toolbox.sh", "with-tillandsias-builder.sh"
-- Every library the delegate sources: a copy missing one fails for that, and a control that
-- fails for that proves nothing (the .sh's copies lacked two, so
-- its P2 control was vacuous).
local FILES = { INCLUDE, DELEGATE, "podman-neutralize-proxy.sh", "lib-env-forward.sh", "lib-dispatch-reap.sh" }
local SRC = {}
for _, f in ipairs(FILES) do
    if not fs.exists("scripts/" .. f) then T:refuse("no-subject", "scripts/" .. f) end
    SRC[f] = fs.read("scripts/" .. f)
end
local NAME = "tillandsias-litmus-fake"
local W = T:scratch()
fs.mkdir(W.rel .. "/fake"); fs.mkdir(W.rel .. "/min")
local function exe(rel, s) fs.write(W.rel .. "/" .. rel, s); T:must{ "chmod", "+x", W.abs .. "/" .. rel } end
-- Records every call, execs nothing, and refuses a duplicate create as the real one does.
exe("fake/toolbox", [==[#!/usr/bin/env bash
set -u
state="${FT_STATE:?FT_STATE unset}"
mkdir -p "$state"
{ printf 'toolbox'; for _a in "$@"; do printf ' %s' "$_a"; done; printf '\n'; } >>"$state/calls.log"
sub="${1:-}"
if [ -n "${FT_FAIL_ON:-}" ] && [ "$sub" = "$FT_FAIL_ON" ]; then echo "fake-toolbox: injected failure on '$sub'" >&2; exit 1; fi
case "$sub" in
    list)
        echo "ID           NAME    CREATED      STATUS   IMAGE NAME"
        if [ -f "$state/containers" ]; then
            while IFS= read -r c; do [ -n "$c" ] || continue; printf 'aaaabbbbcccc %s 1 day ago running fedora-toolbox\n' "$c"; done <"$state/containers"
        fi ;;
    create)
        name=""
        while [ $# -gt 0 ]; do case "$1" in --container) name="${2:-}"; shift 2 ;; *) shift ;; esac; done
        [ -n "$name" ] || { echo "fake-toolbox: create without --container" >&2; exit 2; }
        if [ -f "$state/containers" ] && grep -qxF "$name" "$state/containers"; then echo "fake-toolbox: container '$name' already exists" >&2; exit 1; fi
        echo "$name" >>"$state/containers" ;;
    run)
        case "$*" in
            *"command -v gcc"*) [ -f "$state/initialized" ] || exit 1 ;;
            *dnf*) : >"$state/initialized" ;;
        esac ;;
esac
exit 0
]==])
exe("fake/rpm-ostree", "#!/usr/bin/env bash\nexit 0\n")
exe("fake/curl", "#!/usr/bin/env bash\nexit 22\n") -- the init path fetches cargo-nextest, fail-soft; this never reaches the network
-- native-argv: a tool NAME to look up and link, never a program to spawn
for _, t in ipairs{ "bash", "dirname" } do T:must{ "ln", "-s", fixture.which(t), W.abs .. "/min/" .. t } end

-- A copy of the three scripts under <tag>/, with `edit` applied to one of them: a plain
-- (from, to) replacement that must change it.
local function copy(tag, file, from, to)
    fs.mkdir(W.rel .. "/" .. tag)
    for _, f in ipairs(FILES) do
        local s = SRC[f]
        if f == file then
            local i, j = s:find(from, 1, true)
            if not i then T:refuse("mutation-changed-nothing", tag .. ": scripts/" .. file .. " drifted from: " .. from) end
            local done = {}
            local at = 1
            while i do done[#done + 1] = s:sub(at, i - 1); done[#done + 1] = to; at = j + 1; i, j = s:find(from, at, true) end
            s = table.concat(done) .. s:sub(at)
        end
        exe(tag .. "/" .. f, s)
    end
    return W.abs .. "/" .. tag .. "/" .. INCLUDE
end

local n = 0
local H
local function fresh()
    n = n + 1
    H = { state = "/state" .. n, home = "/home" .. n }
    fs.mkdir(W.rel .. H.state); fs.mkdir(W.rel .. H.home .. "/.cache/tillandsias")
    -- Pre-seeded, so the delegate's init path never reaches the network.
    exe((H.home .. "/.cache/tillandsias/rustup-init.sh"):sub(2), "#!/bin/sh\nexit 0\n")
end
local function run(include, path, extra)
    local e = { PATH = path or (W.abs .. "/fake:" .. env.get("PATH")), HOME = W.abs .. H.home, FT_STATE = W.abs .. H.state, TILLANDSIAS_BUILDER_TOOLBOX = NAME }
    for k, v in pairs(extra or {}) do e[k] = v end
    local r = T:run{ include, cwd = W.abs, env = e, env_unset = { "TILLANDSIAS_*", "TOOLBOX_PATH", "container" } }
    H.last = "rc=" .. tostring(r.code) .. " out=[" .. (r.stdout or ""):sub(-300) .. "] err=[" .. (r.stderr or ""):sub(-500) .. "]"
    return r
end
local function calls(reset)
    local p = W.rel .. H.state .. "/calls.log"
    local s = fs.exists(p) and fs.read(p) or ""
    if reset then fs.write(p, "") end
    local _, created = ("\n" .. s):gsub("\ntoolbox create", "")
    local _, dnf = s:gsub("dnf", "")
    return created, dnf
end
local real = fixture.repo_root() .. "/scripts/" .. INCLUDE
local P = {}
function P.creates(inc)
    fresh()
    local r = run(inc)
    local created, dnf = calls()
    local p = W.rel .. H.state .. "/containers"
    return r.code == 0 and created >= 1 and dnf >= 1 and fs.exists(p) and ("\n" .. fs.read(p)):find("\n" .. NAME .. "\n", 1, true) ~= nil
end
function P.idempotent(inc)
    fresh()
    if run(inc).code ~= 0 or calls(true) < 1 then return false end
    local r = run(inc)
    local created, dnf = calls()
    return r.code == 0 and created == 0 and dnf == 0
end
function P.silent(inc)
    fresh()
    local r = run(inc, W.abs .. "/min")
    return r.code == 0 and (r.stdout or "") == "" and (r.stderr or "") == ""
end
function P.loud(inc)
    fresh()
    local r = run(inc, nil, { FT_FAIL_ON = "create" })
    return r.code ~= 0 and r.code ~= nil and (r.stderr or "") ~= ""
end
function P.delegates(inc)
    fresh()
    local d = "deleg" .. n
    fs.mkdir(W.rel .. "/" .. d)
    exe(d .. "/" .. INCLUDE, inc == real and SRC[INCLUDE] or fs.read(W.rel .. inc:sub(#W.abs + 1)))
    exe(d .. "/" .. DELEGATE, '#!/usr/bin/env bash\ntouch "' .. W.abs .. "/" .. d .. '/delegate-called"\nexit 0\n')
    local r = run(W.abs .. "/" .. d .. "/" .. INCLUDE)
    return r.code == 0 and fs.exists(W.rel .. "/" .. d .. "/delegate-called") and (calls()) == 0
end

local CALL = '"$_ENSURE_TOOLBOX_DIR/with-tillandsias-builder.sh" true'
local function pair(label, pred, mutant)
    T:arm(label, pred(real), H.last)
    T:arm("NEG " .. label .. ": its mutant is refused", not pred(mutant), "the mutant PASSED, so the assertion is vacuous: " .. tostring(H.last))
end
if T:run{ "test", "-f", "/etc/os-release" }.code == 0 then
    T:arm("CONTROL an unmutated copy holds P1 and P2, so a mutant's failure is the mutation's", P.creates(copy("faithful")) and P.idempotent(W.abs .. "/faithful/" .. INCLUDE), H.last)
    pair("P1 creates and initialises a missing toolbox", P.creates, copy("never-ensures", INCLUDE, CALL, "true"))
    pair("P2 a second run creates and installs nothing", P.idempotent, copy("always-creates", DELEGATE, "if ! _toolbox_exists; then", "if true; then"))
    pair("P4 a FAILED ensure is loud", P.loud, copy("swallows-failure", INCLUDE, "return 1 2>/dev/null || exit 1", "return 0 2>/dev/null || exit 0"))
    pair("P5 it delegates and duplicates nothing", P.delegates,
        copy("self-creates", INCLUDE, CALL, 'toolbox create --assumeyes --container "${TILLANDSIAS_BUILDER_TOOLBOX:-tillandsias-builder}"'))
else
    out.line("n/a: P1, P2, P4 and P5 need /etc/os-release, and this host has none")
end
local shebang = SRC[INCLUDE]:match("^[^\n]*\n")
pair("P3 a host with no toolbox gets a silent, successful noop", P.silent, copy("chatty", INCLUDE, shebang, shebang .. 'echo "[ensure_toolbox] no toolbox on this host; skipping"\n'))
T:finish()
