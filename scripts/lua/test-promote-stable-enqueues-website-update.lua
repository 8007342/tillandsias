-- @env PATH
-- @trace order:1846-dykd, order:2300-j4cv, spec:ci-release
--
-- test-promote-stable-enqueues-website-update.lua — promote-stable.sh step 5, ported from
-- the .sh of the same name (2300-j4cv): ONE website-update task when previous-stable..release
-- carries a `Website-Update:` trailer, never a second for the tag, nothing without a trailer,
-- and a failing client defers without failing the promotion. The function is EXTRACTED from
-- scripts/promote-stable.sh and driven on a scratch repo with a stub client.
--
--   1 ORDER      step 5 runs after step 3 is verified and before promoted:
--   2 CAPTURED   the previous stable is read before step 3 moves the tag
--   3 ENQUEUE    exactly one client call, on the site namespace, with the tag and the reason
--   4 NARROW     the payload's keys are kind, tag and reasons, nothing about hosts or the fleet
--   5 IDEMPOTENT a second run for the tag makes no call and says so
--   6 NONE       no trailer in range: no call, no line
--   7 DEFERRED   a failing client defers, returns 0 and leaves no marker, so a re-run enqueues
--   8 NOCLIENT   no client at all defers by name
--
-- Usage: tillandsias-plan script run scripts/lua/test-promote-stable-enqueues-website-update.lua
-- Verdict: ok:promote-stable-enqueues-website-update:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("promote-stable-enqueues-website-update")
local SH = fixture.posix_shell()
local ROOT = fixture.repo_root()
local src = fs.read("scripts/promote-stable.sh")
local fn = ("\n" .. src):match("\n(WEBSITE_NS=.-\n_enqueue_website_update%(%) {.-\n}\n)")
if not fn then T:refuse("no-subject", "_enqueue_website_update() is not in scripts/promote-stable.sh") end

local function at(line) local p = ("\n" .. src):find("\n" .. line, 1, true); return p or 0 end
local verified, step5 = at('echo "verified:stable-tag:$COMMIT"\n'), at('_enqueue_website_update "$PREV_STABLE" "$COMMIT" "$TAG"\n')
local done_, prev = at('echo "promoted:$TAG"\n'), at('PREV_STABLE="$(git')
local move = at('git -C "$REPO_ROOT" tag -f -a stable -m "Stable channel: promoted')
T:arm("1 ORDER step 5 runs after step 3 is verified and before promoted:", verified > 0 and verified < step5 and step5 < done_, verified .. " " .. step5 .. " " .. done_)
T:arm("2 CAPTURED the previous stable is read before the tag moves", prev > 0 and prev < move, prev .. " " .. move)

local r = T:git_repo("repo")
local function git(...)
    local a = { "git", "-C", r.abs, "-c", "user.email=f@x.invalid", "-c", "user.name=f" }
    for _, x in ipairs{ ... } do a[#a + 1] = x end
    return text.trim(T:must(a).stdout or "")
end
local function commit(m) git("commit", "-q", "--allow-empty", "-m", m); return git("rev-parse", "HEAD") end
local v1 = commit("one")
commit("retire local launches\n\nWebsite-Update: local launches are retired; the site lists them as a main feature")
local v2 = commit("two")
local v3 = commit("three, no trailer")

local S = T:scratch("work")
fs.write(S.rel .. "/step5.sh", fn)
fs.write(S.rel .. "/plan", "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '" .. S.abs .. "/calls'\nexit \"${STUB_RC:-0}\"\n")
T:must{ "chmod", "755", S.abs .. "/plan" }
fs.write(S.rel .. "/calls", "")
local function run(from, to, tag, o)
    o = o or {}
    local x = proc.run{ argv = { SH, "-s", "--", S.abs .. "/step5.sh", from, to, tag }, stdin = '. "$1"; shift; _enqueue_website_update "$@" </dev/null\n', cwd = r.abs, timeout_ms = 60000,
        env = { PATH = env.get("PATH"), HOME = S.abs, REPO_ROOT = ROOT, XDG_STATE_HOME = S.abs .. "/state",
            TILLANDSIAS_PLAN_BIN = o.plan or (S.abs .. "/plan"), STUB_RC = o.rc or "0" } }
    return x.code, text.trim(x.stdout or "")
end
local function calls() local n = 0; for _, l in ipairs(text.lines(fs.read(S.rel .. "/calls"))) do if l ~= "" then n = n + 1 end end; return n end

local c, o = run(v1, v2, "v9.0.0")
local sent = fs.read(S.rel .. "/calls")
T:arm("3 ENQUEUE one call, on the site namespace, with the tag and the reason",
    c == 0 and calls() == 1 and text.contains(sent, "--ns 8007342/tillandsias.org") and text.contains(sent, '"tag":"v9.0.0"')
    and text.contains(sent, "local launches are retired") and o == "website-update:enqueued:v9.0.0:ns=8007342/tillandsias.org", o .. " " .. sent)
local body = sent:match("({.*})") or ""
local keys = {}
for k in body:gmatch('"([%w_]+)":') do keys[#keys + 1] = k end
T:arm("4 NARROW the payload's keys are kind, tag and reasons", table.concat(keys, ",") == "kind,tag,reasons", body)
c, o = run(v1, v2, "v9.0.0")
T:arm("5 IDEMPOTENT a second run makes no call and says so", c == 0 and calls() == 1 and o == "website-update:already-enqueued:v9.0.0", o)
c, o = run(v2, v3, "v9.0.1")
T:arm("6 NONE no trailer in range: no call, no line", c == 0 and calls() == 1 and o == "", o)
c, o = run(v1, v2, "v9.0.2", { rc = "7" })
local marker = fs.exists(S.rel .. "/state/tillandsias/website-update/v9.0.2")
local c2, o2 = run(v1, v2, "v9.0.2")
T:arm("7 DEFERRED a failing client defers, returns 0, and a re-run enqueues", c == 0 and o == "website-update:deferred:v9.0.2:client-exit-7" and not marker
    and c2 == 0 and o2:find("^website%-update:enqueued:v9%.0%.2:") ~= nil, o .. " / " .. o2)
c, o = run(v1, v2, "v9.0.3", { plan = S.abs .. "/absent" })
T:arm("8 NOCLIENT no client at all defers by name", c == 0 and o == "website-update:deferred:v9.0.3:no-coordinator-client", o)
T:finish()
