-- @trace order:2239-rmun
-- @env TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-probe-remote-reachable.lua — the remote-unreachable short-circuit's
-- probe (scripts/lua/probe-remote-reachable.lua) against STUB gh and git
-- (bash scripts through its TILLANDSIAS_PROBE_GH/_GIT seams; never the real
-- network, never the real login):
--   1 HEALTHY     both answer -> ok:remote-reachable, exit 0
--   2 GH-AUTH     gh reports no login (the 2026-11-22 outage, its words) ->
--                 blocked:remote-unreachable:gh-auth, exit 1, why/remedy lines
--   3 NEVER-LOGIN across every arm the stub gh records its argv: the probe
--                 never ran `gh auth login` or `gh auth refresh`
--   4 LS-HANG     git ls-remote hangs -> blocked:remote-unreachable:ls-remote-timeout
--                 inside the bounded timeout (no retry: one ls-remote call)
--   5 LS-AUTH     git ls-remote refused credentials -> ...:ls-remote-auth
--   6 GH-HANG     gh hangs (a locked keyring) -> ...:gh-timeout, bounded, remedy names the keyring
--   7 LOCAL       a non-GitHub origin (a fixture's local remote) never asks gh
--
-- Verdict: ok:probe-remote-reachable:<n> or violation:probe-remote-reachable:<failed>.

local BASH = require("common.fixture").posix_shell("/bin/bash") -- Git's bash on native Windows (2246-fkea)
local RUNNER = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if not RUNNER or RUNNER == "" then RUNNER = "target/release/tillandsias-plan" end
local rel = "target/plan-scratch/probe-remote-" .. tostring(time.now_ms())
fs.mkdir(rel)
fs.write(rel .. "/cleanup.sh", 'rm -rf -- "$1"\n')
local function cleanup() proc.run{ argv = { BASH, rel .. "/cleanup.sh", rel }, timeout_ms = 60000 } end

-- Stubs: behaviour from a mode file, every call appended to a log.
fs.write(rel .. "/gh.sh", ([==[
d="@REL@"; echo "gh $*" >> "$d/calls"
case "$(cat "$d/gh.mode")" in
  ok)   echo "github.com"; echo "  ✓ Logged in to github.com account stub (keyring)"; exit 0 ;;
  none) echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2; exit 1 ;;
  hang) sleep 30; exit 0 ;;
esac
]==]):gsub("@REL@", function() return rel end))
fs.write(rel .. "/git.sh", ([==[
d="@REL@"; echo "git $*" >> "$d/calls"
[ "$1" = remote ] && { cat "$d/url"; exit 0; }
case "$(cat "$d/git.mode")" in
  ok)   printf 'f79786f6084a62e797dc3b47ca14e03094f8304b\tHEAD\n'; exit 0 ;;
  hang) sleep 30; exit 0 ;;
  auth) echo "remote: Invalid username or token. Password authentication is not supported for Git operations." >&2
        echo "fatal: Authentication failed for 'https://github.com/x/y.git/'" >&2; exit 128 ;;
esac
]==]):gsub("@REL@", function() return rel end))

local function probe(gh_mode, git_mode, url)
    fs.write(rel .. "/url", (url or "https://github.com/x/y.git") .. "\n")
    fs.write(rel .. "/gh.mode", gh_mode .. "\n"); fs.write(rel .. "/git.mode", git_mode .. "\n")
    fs.write(rel .. "/calls", "")
    local t0 = time.now_ms()
    local p = proc.run{ argv = { RUNNER, "script", "run", "scripts/lua/probe-remote-reachable.lua" },
        env = { TILLANDSIAS_PROBE_GH = rel .. "/gh.sh", TILLANDSIAS_PROBE_GIT = rel .. "/git.sh",
                TILLANDSIAS_PROBE_TIMEOUT_MS = "2000" }, timeout_ms = 60000 }
    return text.trim(p.stdout or ""), p.stderr or "", p.code, time.now_ms() - t0, fs.read(rel .. "/calls") or ""
end

local pass, fail, all_calls = 0, 0, ""
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) log.raw("FAIL: " .. m); fail = fail + 1 end

local o, e, rc, ms, calls = probe("ok", "ok"); all_calls = all_calls .. calls
if o == "ok:remote-reachable" and rc == 0 then ok("1: both healthy -> ok:remote-reachable")
else bad("1: healthy answered [" .. o .. "] rc=" .. tostring(rc) .. " err=[" .. e .. "]") end

o, e, rc, ms, calls = probe("none", "ok"); all_calls = all_calls .. calls
if o == "blocked:remote-unreachable:gh-auth" and rc == 1 and e:find("why:", 1, true) and e:find("remedy:", 1, true) then
    ok("2: gh not logged in -> blocked:remote-unreachable:gh-auth with why/remedy")
else bad("2: no-login answered [" .. o .. "] rc=" .. tostring(rc) .. " err=[" .. e .. "]") end

o, e, rc, ms, calls = probe("ok", "hang"); all_calls = all_calls .. calls
local n_ls = select(2, calls:gsub("git ls%-remote", ""))
if o == "blocked:remote-unreachable:ls-remote-timeout" and rc == 1 and ms < 15000 and n_ls == 1 then
    ok("4: a hung ls-remote -> ls-remote-timeout in " .. ms .. " ms, one call (no retry)")
else bad("4: hung ls-remote answered [" .. o .. "] rc=" .. tostring(rc) .. " in " .. ms .. " ms, ls-remote calls=" .. n_ls) end

o, e, rc, ms, calls = probe("ok", "auth"); all_calls = all_calls .. calls
if o == "blocked:remote-unreachable:ls-remote-auth" and rc == 1 then ok("5: refused git credentials -> ls-remote-auth")
else bad("5: refused credentials answered [" .. o .. "] rc=" .. tostring(rc) .. " err=[" .. e .. "]") end

o, e, rc, ms, calls = probe("hang", "ok"); all_calls = all_calls .. calls
if o == "blocked:remote-unreachable:gh-timeout" and rc == 1 and ms < 15000 and e:find("keyring", 1, true) then
    ok("6: a hung gh (a locked keyring) -> gh-timeout in " .. ms .. " ms, its remedy naming the keyring")
else bad("6: hung gh answered [" .. o .. "] rc=" .. tostring(rc) .. " in " .. ms .. " ms") end

o, e, rc, ms, calls = probe("none", "ok", "/tmp/scratch/remote.git")
if o == "ok:remote-reachable" and rc == 0 and not calls:find("gh ", 1, true) then
    ok("7: a non-GitHub origin (a fixture's local remote) is judged by ls-remote alone; gh is not asked")
else bad("7: local origin answered [" .. o .. "] rc=" .. tostring(rc) .. " calls=[" .. calls .. "]") end

if all_calls:find("gh auth status", 1, true) and not all_calls:find("gh auth login", 1, true)
        and not all_calls:find("gh auth refresh", 1, true) then
    ok("3: across every arm the probe only ran `gh auth status`, never login or refresh")
else bad("3: the probe's gh calls were [" .. all_calls .. "]") end

cleanup()
if fail == 0 then verdict.emit("ok:probe-remote-reachable:" .. pass, 0) end
verdict.emit("violation:probe-remote-reachable:" .. fail, 1)
