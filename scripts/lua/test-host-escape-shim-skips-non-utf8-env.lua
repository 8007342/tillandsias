-- @trace order:2227-shu8, order:934-7jd4, spec:ci-release
--
-- test-host-escape-shim-skips-non-utf8-env.lua — the builder toolbox's
-- host-escape shim (scripts/with-tillandsias-builder.sh,
-- _install_host_escape_shims) must not hand flatpak-spawn a non-UTF-8 --env
-- value: glib refuses it with "Invalid byte sequence in conversion input" and
-- the wrapped tool never runs. The shim body is cut from the script as it
-- ships and run against a STUB flatpak-spawn that refuses non-UTF-8 argv the
-- way glib does, and otherwise prints the --env names it was given.
--   1 a non-UTF-8 TILLANDSIAS_* value: the tool RUNS, that variable is not
--     forwarded, and stderr names it (never the glib conversion error)
--   2 a valid UTF-8 TILLANDSIAS_* value (with a non-ASCII byte) is forwarded
--     unchanged
--   3 MUTATION: the pre-fix body (no UTF-8 test) reproduces the glib refusal,
--     so arm 1 can fail
--
-- Verdict: ok:host-escape-shim-skips-non-utf8-env:<n> or
-- violation:host-escape-shim-skips-non-utf8-env:<failed>.

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local rel = "target/plan-scratch/shim-utf8-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
proc.run{ argv = { "mkdir", "-p", W .. "/bin" } }
local function cleanup() proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end

local pass, fail = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) log.raw("FAIL: " .. m); fail = fail + 1 end

-- The shim as it ships: the heredoc body between <<'SHIM' and SHIM.
local body = proc.run{ argv = { "sed", "-n", "/<<'SHIM'$/,/^SHIM$/{/<<'SHIM'$/d;/^SHIM$/d;p;}",
    root .. "/scripts/with-tillandsias-builder.sh" } }.stdout or ""
if not body:find("flatpak-spawn --host", 1, true) then
    cleanup()
    log.raw("FAIL: could not cut the host-escape shim out of scripts/with-tillandsias-builder.sh — this fixture has drifted from the code it pins")
    verdict.emit("violation:host-escape-shim-skips-non-utf8-env:shim-not-found", 1)
end
fs.write(rel .. "/shim.sh", (body:gsub("TOOL_NAME", "faketool")))
-- Pre-fix body: forward every value, as the shim did before 2227-shu8.
fs.write(rel .. "/shim-prefix.sh", [==[
_fs_args=()
for _v in $(compgen -e); do
    case "$_v" in
        TILLANDSIAS_*|LITMUS_*|FORGE_*|NIX_*|CONTAINER_HOST|DOCKER_HOST)
            _fs_args+=("--env=$_v=${!_v}") ;;
    esac
done
exec flatpak-spawn --host "${_fs_args[@]}" faketool "$@"
]==])

-- Stub flatpak-spawn: glib's refusal for a non-UTF-8 argument, else the
-- forwarded names (and the one value arm 2 checks) and a ran line.
fs.write(rel .. "/bin/flatpak-spawn", [==[#!/usr/bin/env bash
_u8() { local LC_ALL=C.UTF-8; [[ $1 =~ ^.*$ ]]; }
for a in "$@"; do
    _u8 "$a" || { echo "flatpak-spawn: Invalid byte sequence in conversion input" >&2; exit 1; }
done
for a in "$@"; do
    case "$a" in --env=TILLANDSIAS_T_*) echo "fwd:${a#--env=}" ;; esac
done
echo "ran:${*: -1}"
]==])
proc.run{ argv = { "chmod", "+x", W .. "/bin/flatpak-spawn" } }

-- The driver sets the bytes itself (a non-UTF-8 value is set by printf, not
-- carried through the runner's env table), then runs the shim body.
fs.write(rel .. "/drive.sh", [==[
export PATH="$1/bin:$PATH"
export TILLANDSIAS_T_BAD="$(printf 'json\xfe\xff')"
export TILLANDSIAS_T_GOOD="$(printf 'caf\xc3\xa9')"
bash "$2" argone
]==])

local function run(shim)
    local p = proc.run{ argv = { "bash", W .. "/drive.sh", W, W .. "/" .. shim }, timeout_ms = 30000 }
    return p.stdout or "", p.stderr or "", p.code
end

local o, e, rc = run("shim.sh")
if rc == 0 and o:find("ran:argone", 1, true) and not o:find("fwd:TILLANDSIAS_T_BAD", 1, true)
        and e:find("skipped-non-utf8-env:TILLANDSIAS_T_BAD", 1, true)
        and not e:find("Invalid byte sequence", 1, true) then
    ok("1: a non-UTF-8 value is skipped by name and the tool still runs")
else
    bad("1: rc=" .. tostring(rc) .. " stdout=[" .. o .. "] stderr=[" .. e .. "]")
end

if o:find("fwd:TILLANDSIAS_T_GOOD=caf\195\169", 1, true) then
    ok("2: a valid UTF-8 value (non-ASCII) is forwarded unchanged")
else
    bad("2: the valid value was not forwarded unchanged: stdout=[" .. o .. "]")
end

o, e, rc = run("shim-prefix.sh")
if rc ~= 0 and e:find("Invalid byte sequence", 1, true) then
    ok("3: MUTATION: the pre-fix body reproduces the glib refusal, so arm 1 can fail")
else
    bad("3: the pre-fix body did not reproduce the refusal (rc=" .. tostring(rc) .. ") — the stub no longer models glib")
end

cleanup()
if fail == 0 then verdict.emit("ok:host-escape-shim-skips-non-utf8-env:" .. pass, 0) end
verdict.emit("violation:host-escape-shim-skips-non-utf8-env:" .. fail, 1)
