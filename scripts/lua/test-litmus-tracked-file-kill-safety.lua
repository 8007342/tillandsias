-- @trace spec:litmus-framework, spec:versioning, order:2386-lrg1
-- @env PATH HOME
--
-- test-litmus-tracked-file-kill-safety.lua — fixture for order 677-33be: a test that mutates
-- TRACKED files must restore them under every exit, and must repair a previous run's damage on
-- the one exit it cannot catch. Ported from test-litmus-tracked-file-kill-safety.sh (2386-lrg1);
-- same four cases.
--
-- On 2026-08-11 a killed litmus sweep left `0.0.0-test-retag` in VERSION; release-preflight then
-- refused every push on that host with `blocked:version-not-monotonic`.
--
--   0  the SHIPPED convergence test carries both layers (INT/TERM/HUP trap + sentinel repair)
--   1  SIGTERM is catchable, so the trap must restore
--   2  SIGKILL is not, so the NEXT run must repair (it sources the real guard)
--   3  the sweep: no other script redirects into a tracked path unguarded
--
-- PORT NOTE. The victim is proc.spawn'ed (its own process group, killed on leader exit, so its
-- `sleep` cannot outlive it). It writes its own $$ into the ready file, so the signal goes to the
-- victim shell by PID; `:wait()` is the .sh's reap.
--
-- GRAMMAR ok:litmus-tracked-file-kill-safety:<n> arms | violation:litmus-tracked-file-kill-safety:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("litmus-tracked-file-kill-safety")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local SENTINEL = "0.0.0-test-retag"
local CONV = "scripts/test-image-build-convergence.sh"
if not fs.exists(CONV) then T:refuse("subject-missing", CONV) end
local conv = fs.read(CONV)

local function sleep(s) proc.run{ argv = { "/bin/sleep", s }, timeout_ms = 10000 } end

-- The real guard shape: sed -n '/^VERSION_TEST_SENTINEL=/,/^fi$/p'.
local function guard_inc()
    local acc, on = {}, false
    for _, l in ipairs(text.lines(conv)) do
        if not on and l:find("^VERSION_TEST_SENTINEL=") then on = true end
        if on then
            acc[#acc + 1] = l
            if l == "fi" then on = false end
        end
    end
    return table.concat(acc, "\n") .. (#acc > 0 and "\n" or "")
end

local VICTIM = [[#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/guard.inc"
tmp="$(mktemp -d)"
cp "$ROOT/VERSION" "$tmp/VERSION.orig"
cleanup() {
    local rc=$?
    cp "$tmp/VERSION.orig" "$ROOT/VERSION"
    rm -rf "$tmp"
    trap - EXIT INT TERM HUP
    exit "$rc"
}
trap cleanup EXIT INT TERM HUP
printf '0.0.0-test-retag\n' > "$ROOT/VERSION"
echo "$$" > "$ROOT/.victim-ready"
# `sleep N & wait $!`: bash defers a trap until a FOREGROUND command returns (see the .sh).
sleep 20 & wait $!
]]

local function make_repo()
    local d = T:scratch("repo")
    T:must{ "git", "init", "-q", "-b", "main", d.abs }
    T:must{ "git", "-C", d.abs, "config", "user.email", "fixture@example.invalid" }
    T:must{ "git", "-C", d.abs, "config", "user.name", "Fixture" }
    T:must{ "git", "-C", d.abs, "config", "core.autocrlf", "false" }
    T:must{ "git", "-C", d.abs, "config", "commit.gpgsign", "false" }
    fs.write(d.rel .. "/VERSION", "0.4.260812.1\n")
    fs.mkdir(d.rel .. "/scripts")
    fs.write(d.rel .. "/scripts/guard.inc", guard_inc())
    fs.write(d.rel .. "/scripts/victim.sh", VICTIM)
    T:must{ "chmod", "+x", d.abs .. "/scripts/victim.sh" }
    T:must{ "git", "-C", d.abs, "add", "-A" }
    T:must{ "git", "-C", d.abs, "commit", "-qm", "base" }
    return d
end

-- Start the victim and wait (<=10 s) for its poisoned state; returns handle, pid or nil, why.
local function start(d)
    local h = proc.spawn{ argv = { SH, d.abs .. "/scripts/victim.sh" }, timeout_ms = 60000 }
    local ready = d.rel .. "/.victim-ready"
    for _ = 1, 100 do
        if fs.exists(ready) then
            local pid = text.trim(fs.read(ready) or "")
            if pid ~= "" then
                T:run{ "rm", "-f", d.abs .. "/.victim-ready" }
                return h, pid
            end
        end
        sleep("0.1")
    end
    h:kill()
    return nil, nil, "victim never reached its poisoned state"
end
local function signal(h, pid, sig)
    T:run{ "kill", "-" .. sig, pid }
    h:wait()
end
local function version(d) return fs.read(d.rel .. "/VERSION") or "" end
local function poisoned(d) return text.trim(version(d)) == SENTINEL end

-- case 0
local trap_ok = false
for _, l in ipairs(text.lines(conv)) do if l == "trap cleanup EXIT INT TERM HUP" then trap_ok = true end end
T:arm("case 0 the shipped convergence test carries both layers",
    trap_ok and text.contains(conv, "VERSION_TEST_SENTINEL"),
    "trap INT/TERM/HUP=" .. tostring(trap_ok) .. " sentinel=" .. tostring(text.contains(conv, "VERSION_TEST_SENTINEL")))

-- case 1
do
    local d = make_repo()
    local h, pid, why = start(d)
    if not h then T:arm("case 1 SIGTERM restores the tracked file", false, why)
    elseif not poisoned(d) then
        h:kill(); T:arm("case 1 SIGTERM restores the tracked file", false, "setup: VERSION was never poisoned")
    else
        signal(h, pid, "TERM")
        T:arm("case 1 SIGTERM restores the tracked file", not poisoned(d),
            "SIGTERM left VERSION poisoned — EXIT-only trap")
    end
end

-- case 2
do
    local d = make_repo()
    local h, pid, why = start(d)
    if not h then T:arm("case 2 a SIGKILLed run's damage is repaired by the next run", false, why)
    else
        signal(h, pid, "KILL")
        if not poisoned(d) then
            T:arm("case 2 a SIGKILLed run's damage is repaired by the next run", false,
                "setup: SIGKILL was expected to leave the sentinel behind")
        else
            h, pid, why = start(d)
            if not h then T:arm("case 2 a SIGKILLed run's damage is repaired by the next run", false, why)
            else
                signal(h, pid, "TERM")
                T:arm("case 2 a SIGKILLed run's damage is repaired by the next run",
                    not poisoned(d) and version(d) == "0.4.260812.1\n",
                    "VERSION after the repairing run: " .. version(d))
            end
        end
    end
end

-- case 3
do
    local r = T:run{ "grep", "-rnE", [==[>[[:space:]]*"\$(ROOT|REPO_ROOT)"/(VERSION|Cargo\.toml|Cargo\.lock)]==],
        ROOT .. "/scripts" }
    local off = {}
    for _, l in ipairs(text.lines(r.stdout or "")) do
        if l ~= "" and not text.contains(l, "test-image-build-convergence.sh")
            and not text.contains(l, "test-litmus-tracked-file-kill-safety.sh") then off[#off + 1] = l end
    end
    T:arm("case 3 no unguarded tracked-file mutators in scripts/", #off == 0, table.concat(off, "\n"))
end

T:finish()
