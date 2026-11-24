-- @env PATH HOME
-- @trace spec:meta-orchestration, order:1247-omqr, order:1247-amcu, order:1435-ebcx, order:2314-ktxt
--
-- test-claims-affordance.lua — every refusal of check-claims-across-branches.sh says WHY and
-- WHAT would make it not a refusal ("  why: …", "  remedy: …" on stderr), beside an unchanged
-- stdout token. Ported from the .sh of the same name (2314-ktxt); same eight arms.
--
--   1 no-plan-binary, and its remedy clears it     2 fetch-failed, and --no-fetch clears it
--   3 claimed-elsewhere, per packet                4 claimed-elsewhere, --batch
--   5 empty-fold                                   7 unknown-packet
--   8 STATIC: every refusal token sits within six lines of an _afford call
--   9 per-packet with zero siblings refuses (1435-ebcx), and a resolvable sibling clears it
--
-- Every arm runs in a scratch checkout with its own bare origin; the .sh ran five of them in
-- the live checkout, where arm 4 fetched into its refs. 1948-xbaf skips a sibling that is an
-- ancestor of HEAD, so the strict path is pinned. blocked:no-root and --batch's
-- no-siblings-folded are unreachable here: arm 8 covers them.
--
-- Usage: tillandsias-plan script run scripts/lua/test-claims-affordance.lua
-- Verdict: ok:claims-affordance:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("claims-affordance")
local SH = fixture.posix_shell()
local CHECK = fs.read("scripts/check-claims-across-branches.sh")
local PROBE = fs.read("scripts/plan-binary-probe.sh")

local bin = T:scratch("bin")
-- status: what the stub answers ("" is unknown); ready: what `ready any` prints.
local function stub(name, status, ready)
    fs.mkdir(bin.rel .. "/" .. name)
    fs.write(bin.rel .. "/" .. name .. "/tillandsias-plan", '#!/bin/sh\ncase " $* " in\n    *" ready any "*) printf \'%s\' "' .. ready
        .. '" ;;\n    *" status "*) [ -n "' .. status .. '" ] || exit 1; echo "PKT\t' .. status .. '\tsome-packet-name" ;;\nesac\nexit 0\n')
    local p = bin.abs .. "/" .. name .. "/tillandsias-plan"
    T:must{ "chmod", "+x", p }
    return p
end
local HOLD, EMPTY = stub("hold", "in_progress", "OTHER-PKT\n"), stub("empty", "in_progress", "")
local UNKNOWN, FREE = stub("unknown", "", "OTHER-PKT\n"), stub("free", "ready", "SOME-PKT\n")

local function checkout()
    local d = T:git_repo()
    fs.mkdir(d.rel .. "/scripts"); fs.mkdir(d.rel .. "/plan/index.d")
    fs.write(d.rel .. "/scripts/check-claims-across-branches.sh", CHECK)
    fs.write(d.rel .. "/scripts/plan-binary-probe.sh", PROBE)
    fs.write(d.rel .. "/plan/index.yaml", "packets: []\n")
    -- Tracked, or `git archive plan/index.d` fails and the check folds nothing.
    fs.write(d.rel .. "/plan/index.d/empty.yaml", "packets: []\n")
    T:must{ "git", "-C", d.abs, "add", "-A" }
    T:must{ "git", "-C", d.abs, "commit", "-q", "-m", "base" }
    T:must{ "git", "-C", d.abs, "switch", "-q", "-c", "work/fixture" }
    return d
end
local function run(d, plan, ...)
    local r = proc.run{ argv = { SH, "scripts/check-claims-across-branches.sh", ... }, cwd = d.abs, timeout_ms = 60000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = plan, TILLANDSIAS_XBRANCH_ANCESTOR_SKIP = "0",
            TILLANDSIAS_XBRANCH_CLAIM_HOST = "some-other-host" }, env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" } }
    local o, e = (r.stdout or ""):gsub("\r", ""), "\n" .. (r.stderr or ""):gsub("\r", "")
    return { rc = r.code, out = o, first = o:match("^[^\n]*"), err = e, why = "rc=" .. tostring(r.code) .. " [" .. o .. "] " .. e,
        afford = text.contains(e, "\n  why: ") and text.contains(e, "\n  remedy: ") }
end
local function starts(s, p) return s:sub(1, #p) == p end

local origin = T:scratch("origin")
T:must{ "git", "init", "-q", "--bare", origin.abs }
local R = checkout()
T:must{ "git", "-C", R.abs, "remote", "add", "origin", origin.abs }
for _, b in ipairs{ "linux-next", "windows-next", "osx-next" } do T:must{ "git", "-C", R.abs, "push", "-q", "origin", "HEAD:refs/heads/" .. b } end
T:must{ "git", "-C", R.abs, "fetch", "-q", "origin" }

local x = run(R, bin.abs .. "/nonexistent", "SOME-PKT", "--no-fetch")
local y = run(R, FREE, "SOME-PKT", "--no-fetch")
T:arm("1 no-plan-binary carries its affordance, and a runnable TILLANDSIAS_PLAN_BIN clears it",
    x.rc == 2 and x.first == "blocked:no-plan-binary" and x.afford and y.rc == 0, x.why .. " then " .. y.why)
x = run(R, HOLD, "SOME-PKT", "--no-fetch")
T:arm("3 claimed-elsewhere per packet carries its affordance", x.rc == 1 and starts(x.first, "claimed-elsewhere:SOME-PKT:") and x.afford, x.why)
x = run(R, HOLD, "--batch", "SOME-PKT")
T:arm("4 claimed-elsewhere in --batch carries its affordance", x.rc == 1 and text.contains("\n" .. x.out, "\nclaimed-elsewhere:SOME-PKT:") and x.afford, x.why)
x = run(R, EMPTY, "--batch", "SOME-PKT")
T:arm("5 empty-fold carries its affordance", text.contains(x.err, "\nblocked:empty-fold:") and x.afford, x.why)
x = run(R, UNKNOWN, "NO-SUCH-PKT", "--no-fetch")
T:arm("7 unknown-packet carries its affordance", x.rc == 2 and starts(x.first, "unknown-packet:NO-SUCH-PKT:") and x.afford, x.why)

T:must{ "git", "-C", R.abs, "remote", "set-url", "origin", origin.abs .. "-no-such-remote" }
x = run(R, FREE, "SOME-PKT")
y = run(R, FREE, "SOME-PKT", "--no-fetch")
T:arm("2 fetch-failed carries its affordance, and --no-fetch clears it",
    x.rc == 2 and x.first == "blocked:fetch-failed" and x.afford and y.rc == 0, x.why .. " then " .. y.why)

local R0 = checkout()
x = run(R0, FREE, "SOME-PKT", "--no-fetch")
T:must{ "git", "-C", R0.abs, "update-ref", "refs/remotes/origin/linux-next", "HEAD" }
y = run(R0, FREE, "SOME-PKT", "--no-fetch")
T:arm("9 zero siblings refuses per packet with its affordance, and one sibling clears it to an ok counting one",
    x.rc == 2 and x.first == "blocked:no-siblings-folded" and x.afford and y.rc == 0 and starts(y.first, "ok:cross-branch-claims:1"), x.why .. " then " .. y.why)

local lines, sites, bare = {}, 0, {}
for l in (CHECK .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
for i, l in ipairs(lines) do
    if text.contains(l, 'echo "blocked:') or text.contains(l, 'echo "claimed-elsewhere:') or text.contains(l, 'echo "unknown-packet:') then
        sites = sites + 1
        local found = false
        for j = math.max(1, i - 6), math.min(#lines, i + 6) do if text.contains(lines[j], "_afford ") then found = true end end
        if not found then bare[#bare + 1] = i .. ": " .. l end
    end
end
T:arm("8 every refusal site sits beside an _afford call", sites > 0 and #bare == 0, sites .. " sites; " .. table.concat(bare, " | "))
T:finish()
