-- @env PATH HOME
-- @trace order:1261-bn7v, order:1458-8y85, order:2285-cbtf, order:2367-wtse
--
-- test-append-vs-origin-fold.lua — check-append-vs-origin-fold.sh refuses an append that drops a
-- line origin's fold holds. Ported from the .sh of the same name (2367-wtse). Scratch
-- repositories whose origin/linux-next is a local ref.
--
--   1 a stale-base append is refused, naming the line    2 a current-base one is admitted
--   3 the same scoped to the push                        4 what each scope folds
--   5 a spent deadline is could-not-run, exit 3          6 a --replace acknowledging origin's value
--   is admitted   7 one against a stale fold is refused
--
-- Usage: tillandsias-plan script run scripts/lua/test-append-vs-origin-fold.lua
-- Verdict: ok:append-vs-origin-fold:<n> arms | violation:... | skip:append-vs-origin-fold:...

local fixture = require "common.fixture"
local T = fixture.new("append-vs-origin-fold")
local SH, PLAN = fixture.posix_shell(), fixture.plan_binary()
if PLAN == "" then T:skip("no-plan-binary") end
local E = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = PLAN }
local L1 = "L1-PEER-WARNING-DO-NOT-DROP"
local PUSHED, ORIGIN = "plan/index.d/20260101t000002z-push-hostb.yaml", "plan/index.d/20260101t000001z-origin-hosta.yaml"
local function frag(field, ts, host, body, extra)
    local lines = {}
    for l in (body .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l == "" and "" or "      " .. l end
    return "status:\n  - packet_id: fixture-packet\n    field: " .. field .. "\n    value: |-\n" .. table.concat(lines, "\n") .. '\n    ts: "2026-01-01T00:00:0' .. ts .. 'Z"\n    host: ' .. host .. "\n" .. (extra or "")
end
local function L1_AT(tail) return "BASE LINE.\n\n[2026-01-01T00:00:01Z host-a] " .. L1 .. (tail or "") end
local function repo(with_l1)
    local d = T:git_repo()
    fs.mkdir(d.rel .. "/plan/index.d"); fs.mkdir(d.rel .. "/scripts")
    for _, s in ipairs{ "check-append-vs-origin-fold.sh", "plan-binary-probe.sh" } do fs.write(d.rel .. "/scripts/" .. s, fs.read("scripts/" .. s)) end
    fs.write(d.rel .. "/plan/index.yaml", "packets:\n  - packet_id: fixture-packet\n    order: 950-fix\n    status: ready\n    next_action: |\n      BASE LINE.\n")
    fs.write(d.rel .. "/" .. ORIGIN, frag("next_action", 1, "host-a", L1_AT()))
    local function land(m)
        T:must{ "git", "-C", d.abs, "add", "-A" }; T:must{ "git", "-C", d.abs, "commit", "-qm", m }
        T:must{ "git", "-C", d.abs, "update-ref", "refs/remotes/origin/linux-next", "HEAD" }
    end
    land("origin-state")
    d.landed = function(name, body) fs.write(d.rel .. "/plan/index.d/" .. name, body); T:must{ "git", "-C", d.abs, "add", "plan/index.d/" .. name }
        T:must{ "git", "-C", d.abs, "commit", "-qm", name }; T:must{ "git", "-C", d.abs, "update-ref", "refs/remotes/origin/linux-next", "HEAD" } end
    d.push = function(body, extra) fs.write(d.rel .. "/" .. PUSHED, frag("next_action", 2, "host-b", body, extra)) end
    d.push(with_l1 and L1_AT("\n\n[2026-01-01T00:00:02Z host-b] L2-FROM-A-CURRENT-BASE") or "BASE LINE.\n\n[2026-01-01T00:00:02Z host-b] L2-FROM-A-STALE-BASE")
    return d
end
local function check(d, arg, more)
    local e = {}
    for k, v in pairs(E) do e[k] = v end
    for k, v in pairs(more or {}) do e[k] = v end
    local r = proc.run{ argv = { SH, "scripts/check-append-vs-origin-fold.sh", arg }, cwd = d.abs, env = e, env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = 120000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    return { rc = r.code, o = o, t = text.trim(o), why = "rc=" .. tostring(r.code) .. " " .. o:sub(1, 400) }
end
local REFUSED = "refused:append-drops-lines-vs-origin:fixture-packet:next_action"
local function dropped(x) return x.rc ~= 0 and text.contains(x.o, REFUSED) and text.contains(x.o, L1) end
local function unrelated(d) d.landed("20260101t000000z-unrelated-hostc.yaml", frag("context", 0, "host-c", "UNRELATED CONTEXT LINE.")) end

local x = check(repo(false))
T:arm("1 a stale-base append is refused and names the dropped line", dropped(x), x.why)
x = check(repo(true))
T:arm("2 a current-base append is admitted", x.rc == 0 and x.o:sub(1, 28) == "ok:append-vs-origin:checked:", x.why)
local d = repo(false); unrelated(d)
x = check(d, PUSHED)
T:arm("3 scoped to the push, it is still refused", dropped(x), x.why)
d = repo(true); unrelated(d)
local a, b, c = check(d, PUSHED), check(d, "--all"), check(d)
T:arm("4a scoped folds 1 pair, --all 2, a bare run the 1 that differs", a.t == "ok:append-vs-origin:checked:1" and b.t == "ok:append-vs-origin:checked:2" and c.t == "ok:append-vs-origin:checked:1", a.t .. " / " .. b.t .. " / " .. c.t)
fs.write(d.rel .. "/plan/index.yaml", fs.read(d.rel .. "/plan/index.yaml") .. "\n# base changed\n")
x = check(d)
T:arm("4b a differing base folds the whole corpus", x.t == "ok:append-vs-origin:checked:2", x.why)
d = repo(true); d.landed("20260101t000000z-older-hostd.yaml", frag("next_action", 0, "host-d", "BASE LINE."))
T:must{ "rm", "-f", d.abs .. "/" .. PUSHED, d.abs .. "/" .. ORIGIN }
x = check(d)
T:arm("4c an origin fragment missing here is still compared", dropped(x), x.why)
d = repo(true); T:must{ "rm", "-f", d.abs .. "/" .. PUSHED, d.abs .. "/" .. ORIGIN }
a, b = check(d), check(d, "--all")
T:arm("4d a tree behind origin reads the same narrowed and whole", a.t == "ok:append-vs-origin:checked:0" and b.t == a.t, a.t .. " / " .. b.t)
d = repo(true); T:must{ "rm", "-f", d.abs .. "/" .. PUSHED }
x = check(d)
T:arm("4e a tree equal to origin folds nothing", x.t == "ok:append-vs-origin:checked:0", x.why)
x = check(repo(true), PUSHED, { TILLANDSIAS_APPEND_FOLD_DEADLINE = "0" })
T:arm("5 a spent deadline is a named could-not-run, exit 3", x.rc == 3 and x.o:sub(1, 40) == "could-not-run:append-vs-origin:deadline:", x.why)
local function sha(s) local r = T:run{ PLAN, "hash", "sha256", "-", stdin = s }; return text.trim(r.stdout or "") end
d = repo(true); T:must{ "rm", "-f", d.abs .. "/" .. PUSHED }
local folded = proc.run{ argv = { PLAN, "field-get", "fixture-packet", "next_action" }, cwd = d.abs, env = E, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
d.push("BASE LINE, REVIEWED AND REWRITTEN.", '    replaces_sha256: "' .. sha((folded.stdout or ""):gsub("\n+$", "")) .. '"\n')
x = check(d, PUSHED)
T:arm("6 a --replace acknowledging origin's value is admitted", x.rc == 0 and text.contains(x.o, "ok:append-vs-origin:checked:1:admitted-replace:1"), x.why)
d = repo(true); d.push("BASE LINE, REVIEWED AND REWRITTEN.", '    replaces_sha256: "' .. sha("BASE LINE.") .. '"\n')
x = check(d, PUSHED)
T:arm("7 one written against a stale fold is refused", x.rc ~= 0 and text.contains(x.o, REFUSED .. ":replace-against-stale-fold"), x.why)
T:finish()
