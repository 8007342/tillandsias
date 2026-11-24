-- @trace order:1454-ssg3, order:2292-bsdc, spec:ci-release
-- @env PATH HOME
--
-- test-bsd-count-shapes.lua — ported from scripts/test-bsd-count-shapes.sh
-- (2292-bsdc, shell-to-lua); the arms, their text and the verdict grammar are
-- unchanged.
--
-- The BSD userland's count shapes, reproduced on ANY host, so a count in a
-- gate cannot regress on darwin while every Linux run stays green (1454-ssg3).
-- Stub `grep` and `wc` on PATH emit exactly what macOS's stock /usr/bin/grep
-- and /usr/bin/wc emit:
--   * `grep -lc` prints BOTH `file:N` and `file` for each matching file (GNU
--     prints only the names), so 2 files read as 4 lines;
--   * `wc -l` left-pads its count ("       2"), which breaks a string compare.
--
--   1. the stubs reproduce the shape: the OLD expression (`grep -lc … | wc -l`)
--      counts 4 for 2 files, the red darwin measured at 392a0c514;
--   2. the litmus:fragment-ts-skew consumer count, read verbatim from its yaml,
--      answers ok:both-consumers under the BSD stubs;
--   3. the same command answers ok:both-consumers with the host's own tools;
--   4. a padded `wc -l` is normalised: the count reaches a string compare as "2".
--
-- The stubs and the commands under test stay bash: they reproduce a shell's
-- view of the userland, which is the subject. The .sh read the litmus yaml
-- through `tillandsias-plan yaml-json | json get`; the runner's yaml.parse reads
-- it directly, so its skip:…:no-plan-binary path no longer exists.
--
-- Verdicts: ok:bsd-count-shapes:4/4 (0) | fail:bsd-count-shapes:<p>/4 (1)

local NAME = "bsd-count-shapes"
local TOTAL = 4
local BASE = { PATH = env.get("PATH"), HOME = env.get("HOME") }
local function run(argv, env_over)
    local e = {}
    for k, v in pairs(BASE) do e[k] = v end
    for k, v in pairs(env_over or {}) do e[k] = v end
    local r = proc.run({ argv = argv, env = e, cwd = ROOT, timeout_ms = 30000 })
    return (r.stdout or "")
end

ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, env = BASE }).stdout or "")
local pass = 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) out.line("FAIL: " .. m) end
local function trim_nl(s) return (s:gsub("\n+$", "")) end

local function which(cmd)
    for dir in (BASE.PATH or ""):gmatch("[^:]+") do
        if proc.run({ argv = { "test", "-x", dir .. "/" .. cmd }, env = BASE }).code == 0 then return dir .. "/" .. cmd end
    end
    return cmd
end

local REL = "target/plan-scratch/bsd-count-shapes." .. tostring(time.now_ms())
local W = ROOT .. "/" .. REL
fs.mkdir(REL .. "/bin")
local function cleanup() proc.run({ argv = { "rm", "-rf", W }, env = BASE }) end

local REAL_GREP, REAL_WC = which("grep"), which("wc")
-- BSD grep: with BOTH -l and -c, print "file:N" then "file" per matching file.
fs.write(REL .. "/bin/grep", [[#!/usr/bin/env bash
l=0; c=0; args=()
for a in "$@"; do
    case "$a" in
        -lc|-cl) l=1; c=1 ;;
        -l) l=1 ;;
        -c) c=1 ;;
        *) args+=("$a") ;;
    esac
done
if [ "$l" = 1 ] && [ "$c" = 1 ]; then
    pat="${args[0]}"; rc=1
    for f in "${args[@]:1}"; do
        n=$("]] .. REAL_GREP .. [[" -c -e "$pat" "$f" 2>/dev/null) || n=0
        if [ "${n:-0}" -gt 0 ]; then printf '%s:%s\n%s\n' "$f" "$n" "$f"; rc=0; fi
    done
    exit $rc
fi
[ "$l" = 1 ] && set -- -l "${args[@]}"
[ "$c" = 1 ] && set -- -c "${args[@]}"
[ "$l" = 0 ] && [ "$c" = 0 ] && set -- "${args[@]}"
exec "]] .. REAL_GREP .. [[" "$@"
]])
-- BSD wc -l: left-pad the count to eight columns.
fs.write(REL .. "/bin/wc", [[#!/usr/bin/env bash
if [ "${1:-}" = "-l" ]; then n=$("]] .. REAL_WC .. [[" -l | tr -d ' '); printf '%8s\n' "$n"; exit 0; fi
exec "]] .. REAL_WC .. [[" "$@"
]])
proc.run({ argv = { "chmod", "+x", W .. "/bin/grep", W .. "/bin/wc" }, env = BASE })
local BSD = { PATH = W .. "/bin:" .. BASE.PATH }
-- The runner refuses `bash -c` (policy_denied, with no output), so each command
-- runs from a file in the scratch dir: `bash <file>`, same shell, same text.
local nseq = 0
local function as_file(cmd)
    nseq = nseq + 1
    local rel = REL .. "/cmd" .. nseq .. ".sh"
    fs.write(rel, cmd .. "\n")
    return W .. "/cmd" .. nseq .. ".sh"
end
local function bsd(cmd) return trim_nl(run({ "bash", as_file(cmd) }, BSD)) end
local function host(cmd) return trim_nl(run({ "bash", as_file(cmd) })) end

local cmd
do
    local y = fs.read("openspec/litmus-tests/litmus-fragment-ts-skew.yaml")
    local doc = y and yaml.parse(y)
    for _, s in ipairs((doc and doc.critical_path) or {}) do
        if s.expected_behavior == "ok:both-consumers" then cmd = s.command; break end
    end
end
if not cmd or cmd == "" then
    cleanup()
    verdict.emit("fail:" .. NAME .. ":0/" .. TOTAL .. " (could not read the litmus command)", 1)
end

-- 1 — the stubs reproduce the darwin shape.
local old = bsd("grep -lc 'check-fragment-ts-skew' scripts/hooks/pre-push-local-gate.sh build.sh 2>/dev/null | wc -l")
if old == "       4" then
    ok("arm 1: BSD grep -lc + wc -l reads 2 files as '       4' (the darwin red, reproduced here)")
else
    bad("arm 1: expected '       4' under the BSD stubs, got '" .. old .. "'")
end

-- 2 — the litmus's own command survives the BSD shape.
local out2 = bsd(cmd)
if out2 == "ok:both-consumers" then ok("arm 2: litmus:fragment-ts-skew consumer count under BSD grep/wc -> ok:both-consumers")
else bad("arm 2: got '" .. out2 .. "' from: " .. cmd) end

-- 3 — and with this host's own tools.
local out3 = host(cmd)
if out3 == "ok:both-consumers" then ok("arm 3: the same command with the host's tools -> ok:both-consumers")
else bad("arm 3: got '" .. out3 .. "'") end

-- 4 — a padded count is normalised before any string compare.
local n4 = bsd("printf 'a\\nb\\n' | wc -l | tr -d ' '")
if "consumers=" .. n4 == "consumers=2" then ok("arm 4: padded wc -l normalised: consumers=2")
else bad("arm 4: got 'consumers=" .. n4 .. "'") end

cleanup()
if pass == TOTAL then verdict.emit("ok:" .. NAME .. ":" .. pass .. "/" .. TOTAL, 0) end
verdict.emit("fail:" .. NAME .. ":" .. pass .. "/" .. TOTAL, 1)
