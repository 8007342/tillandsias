-- @trace order:2275-fcpy
-- inputs: scripts/lua/test-preflight-bench.lua build.sh lib/lua/common/ crates/tillandsias-plan/
--
-- test-preflight-bench.lua — build.sh's preflight bench (_pf_bench_blobs, _load,
-- _save), extracted and run over a scratch roster and record file.
--   1 TWICE     over on two doors in a row -> benched, with its bound
--   2 ONCE      over once -> started
--   3 CHANGED   benched, then its file changes -> started
--   4 FINISHES  over, done, over -> never benched (a finish forgets)
--   5 ADVISORY  missing, garbage, half-garbage and foreign-host records bench
--               nothing from what they cannot vouch for, and every call exits 0
--   6 AGE       retried at 24 h; a record from the future is not honoured
--   7 DEADLINE  a longer deadline than the recorded bound -> started; a check-*
--               is compared with the DECIDER deadline
--   8 ARGS      the same path in two modes is two guards
--   9 UNWRITABLE a record that cannot be written changes nothing, exit 0
--  11 CONTENDED an "over" in a contended or unmeasured door is not recorded
--  12 MEASURE   cpu others used, pressure, thresholds; unreadable is contended
--  13 IDENTITY  machine id (hashed) + locus; no host id in a container: no bench
--  14 WRITER   the save checks the header too
--  10 DOOR      the door counts benched guards as UNANSWERED (never ok:) and in
--               the roster sum, and --full / an overridden deadline turn it off
--
-- Verdict: ok:preflight-bench:<n> arms | violation:preflight-bench:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("preflight-bench")
local SH = fixture.posix_shell()
local SRC = fs.read("build.sh")
local fns = {}
for _, n in ipairs({ "_pf_bench_host", "_pf_bench_contention", "_pf_bench_quiet", "_pf_bench_blobs", "_pf_bench_load", "_pf_bench_save" }) do
    local body = SRC:match("\n(" .. n .. "%(%) {.-\n}\n)")
    if not body then verdict.emit("violation:preflight-bench:no-subject:" .. n, 1) end
    fns[#fns + 1] = body
end
local W = T:scratch("b")
fs.mkdir(W.rel .. "/repo/scripts")
T:must{ "git", "init", "-q", W.abs .. "/repo" }
for _, c in ipairs({ "_PF_BENCH_MAX_SOME", "_PF_BENCH_MAX_FOREIGN" }) do
    fns[#fns + 1] = SRC:match("\n(" .. c .. "=%d+)\n") or verdict.emit("violation:preflight-bench:no-subject:" .. c, 1)
end
fs.write(W.rel .. "/fns.sh", table.concat(fns, "\n") .. "\n")
fs.write(W.rel .. "/run.sh", [[
set -euo pipefail
# $1 = load|save  $2 = repo  $3 = work dir  $4 = record  $5 = now  [$6 dl $7 ddl] ; save: $6 = quiet
SCRIPT_DIR="$2"; . "${0%/*}/fns.sh"
case "$1" in
    host) _pf_bench_host || echo none; exit 0 ;;
    contention) _pf_bench_contention "$3" "$4" || echo unmeasured; exit 0 ;;
    quiet) _pf_bench_quiet "$3" "$4" && echo quiet || echo contended; exit 0 ;;
esac
_pf_bench_blobs "$3" || exit 9
case "$1" in
    load) _pf_bench_load "$3" "$4" "${6:-5}" "${7:-5}" "$5" ;;
    save) _pf_bench_save "$3" "$4" "$5" "${6:-1}" ;;
esac
]])
local function ask(verb, a, b, env2)
    local r = proc.run{ argv = { SH, W.abs .. "/run.sh", verb, W.abs .. "/repo", a or "", b or "" }, env = env2, timeout_ms = 10000 }
    return text.trim(r.stdout or "")
end
local HEAD = "# preflight-bench v2 " .. ask("host") .. "\n"
local NOW = 1800000000
local seq, rcs = 0, {}
local function put(name, body) fs.write(W.rel .. "/repo/scripts/" .. name, body) end
local function call(verb, rec, roster, outcomes, now, dl, ddl)
    seq = seq + 1
    local d = W.rel .. "/w" .. seq
    fs.mkdir(d)
    fs.write(d .. "/roster", roster)
    if outcomes then fs.write(d .. "/outcomes", outcomes) end
    local argv = { SH, W.abs .. "/run.sh", verb, W.abs .. "/repo", W.abs .. "/w" .. seq, rec, tostring(now or NOW) }
    if dl then argv[#argv + 1] = tostring(dl); argv[#argv + 1] = tostring(ddl or dl) end
    local r = proc.run{ argv = argv, timeout_ms = 20000 }
    if r.code ~= 0 then rcs[#rcs + 1] = verb .. ":" .. tostring(r.code) .. ":" .. (r.stderr or "") end
    return d
end
local function rec(n) return W.abs .. "/" .. n .. ".tsv" end
local function save(n, what, path, now, dl, args)
    local p = path or "scripts/test-a.sh"
    call("save", rec(n), p .. "\n", p .. "\t" .. (args or "-") .. "\t" .. what .. "\t" .. (dl or 5) .. "\n", now)
end
-- benched(n, roster, idx, ...): the .benched file of roster line idx, or nil
local function benched(n, roster, idx, now, dl, ddl)
    local d = call("load", rec(n), roster or "scripts/test-a.sh\n", nil, now, dl, ddl)
    local f = d .. "/" .. (idx or 1) .. ".benched"
    return fs.exists(f) and text.trim(fs.read(f)) or nil
end
put("test-a.sh", "a\n"); put("check-b.sh", "b\n")

save("two", "over"); save("two", "over", nil, NOW + 10)
local b = benched("two", nil, nil, NOW + 20)
T:arm("1 TWICE over on two doors in a row is benched, with its bound", b == "5 " .. (NOW + 10), b)

save("one", "over")
T:arm("2 ONCE over once is started", benched("one") == nil, "benched")

save("chg", "over"); save("chg", "over")
local before = benched("chg")
put("test-a.sh", "a changed\n")
local after = benched("chg")
put("test-a.sh", "a\n")
T:arm("3 CHANGED a benched guard whose file changed is started", before ~= nil and after == nil,
    "before=" .. tostring(before) .. " after=" .. tostring(after))

save("fin", "over"); save("fin", "done"); save("fin", "over")
T:arm("4 FINISHES a guard that finished in between is not benched", benched("fin") == nil, "benched")

local blob = text.trim(proc.run{ argv = { "git", "hash-object", "--no-filters", W.abs .. "/repo/scripts/test-a.sh" }, timeout_ms = 5000 }.stdout or "")
local function line(extra) return "scripts/test-a.sh\t-\t" .. blob .. "\t2\t5\t" .. NOW .. (extra or "") .. "\n" end
fs.write(W.rel .. "/ctl.tsv", HEAD .. line())
fs.write(W.rel .. "/garb.tsv", "\1\2 not a record\n\tx\n")
fs.write(W.rel .. "/half.tsv", HEAD .. "scripts/test-a.sh\t-\t" .. blob .. "\tmany\t5\t" .. NOW .. "\n" .. line("\textra"))
fs.write(W.rel .. "/for.tsv", "# preflight-bench v2 some-other-host\n" .. line())
fs.write(W.rel .. "/v1.tsv", (HEAD:gsub(" v2 ", " v1 ")) .. line())
fs.write(W.rel .. "/empty.tsv", "")
local leaked = {}
for _, n in ipairs({ "missing", "garb", "half", "for", "v1", "empty" }) do
    if benched(n) then leaked[#leaked + 1] = n end
end
T:arm("5 ADVISORY missing, garbage, half-garbage, foreign, v1 and empty records bench nothing (the control does)",
    benched("ctl") ~= nil and #leaked == 0, "control=" .. tostring(benched("ctl")) .. " leaked=" .. table.concat(leaked, ","))

T:arm("6 AGE honoured at 23 h 59 m, retried at 24 h, and a future record is not honoured",
    benched("ctl", nil, nil, NOW + 86340) ~= nil and benched("ctl", nil, nil, NOW + 86400) == nil
        and benched("ctl", nil, nil, NOW - 60) == nil, "age")

save("chk", "over", "scripts/check-b.sh"); save("chk", "over", "scripts/check-b.sh")
T:arm("7 DEADLINE a longer deadline is a new question, and a check-* is asked the decider's",
    benched("ctl", nil, nil, nil, 6, 6) == nil and benched("ctl", nil, nil, nil, 5, 20) ~= nil
        and benched("chk", "scripts/check-b.sh\n", 1, nil, 5, 5) ~= nil
        and benched("chk", "scripts/check-b.sh\n", 1, nil, 5, 20) == nil, "deadline")

save("arg", "over", nil, nil, nil, "fixture"); save("arg", "over", nil, nil, nil, "fixture")
local two = "scripts/test-a.sh\nscripts/test-a.sh\tfixture\n"
T:arm("8 ARGS the same path in two modes is two guards",
    benched("arg", two, 1) == nil and benched("arg", two, 2) ~= nil, "args")

fs.write(W.rel .. "/afile", "x")
call("save", W.abs .. "/afile/sub/rec.tsv", "scripts/test-a.sh\n", "scripts/test-a.sh\t-\tover\t5\n")
T:arm("9 UNWRITABLE no call exited non-zero, over every record above", #rcs == 0, table.concat(rcs, " | "):sub(1, 300))

T:arm("10 DOOR benched is counted in the sum and as unanswered, and off under --full or an overridden deadline",
    SRC:find("_pf_unanswered=$(( _pf_deadline_n + _pf_bench_n + _pf_cantrun ))", 1, true) ~= nil
        and SRC:find("_pf_deadline_n + _pf_bench_n + _pf_cantrun + _pf_failed ))", 1, true) ~= nil
        and SRC:find('if [[ "$FLAG_PREFLIGHT_FULL" != true ]] && [ "${TILLANDSIAS_PREFLIGHT_BENCH:-on}" != off ]', 1, true) ~= nil
        and SRC:find('&& [ -z "${TILLANDSIAS_PREFLIGHT_TIMEOUT:-}" ]; then\n        _pf_bench_file=', 1, true) ~= nil,
    "build.sh wiring")
-- 11: the coordinator's mutant (2026-11-24): doors under load bench nothing
local function loud(n, what, now)
    call("save", rec(n), "scripts/test-a.sh\n", "scripts/test-a.sh\t-\t" .. what .. "\t5\n", now, 0)
end
loud("load", "over"); loud("load", "over"); loud("load", "over")
local never = benched("load")
save("mix", "over"); loud("mix", "over")
local mixed = benched("mix")
save("cl", "over"); save("cl", "over"); loud("cl", "done")
T:arm("11 CONTENDED three overs in contended doors bench nothing, one quiet over plus a contended one is not two, and a finish still forgets",
    never == nil and mixed == nil and benched("cl") == nil and #rcs == 0,
    "never=" .. tostring(never) .. " mixed=" .. tostring(mixed) .. " " .. table.concat(rcs, "|"):sub(1, 200))

-- 12: 16 cores, 100 s: 160000 jiffies; door own 20000
local S0 = "1000 10000 50 0 0"
T:arm("12 MEASURE the percent others used, and what cannot be read is contended",
    ask("contention", S0, "22200 170000 20050 500000 100") == "0 0"
        and ask("contention", S0, "101000 170000 20050 2000000 100") == "2 50"
        and ask("contention", "", "1 2 3 4 5") == "unmeasured" and ask("contention", S0, S0) == "unmeasured"
        and ask("quiet", "0", "0") == "quiet" and ask("quiet", "2", "50") == "contended"
        and ask("quiet", "29", "0") == "contended" and ask("quiet", "", "") == "contended"
        and ask("quiet", "3", "15") == "quiet" and ask("quiet", "4", "15") == "contended" and ask("quiet", "3", "16") == "contended",
    ask("contention", S0, "101000 170000 20050 2000000 100"))

-- 13: identity
local function root(n, files)
    for f, b in pairs(files) do
        fs.mkdir(W.rel .. "/" .. n .. "/" .. f:match("^(.*)/[^/]+$")); fs.write(W.rel .. "/" .. n .. "/" .. f, b)
    end
    return ask("host", nil, nil, { TILLANDSIAS_PREFLIGHT_BENCH_HOSTROOT = W.abs .. "/" .. n })
end
local box = { ["run/.containerenv"] = "", ["etc/machine-id"] = "image-id\n" }
local A = root("ha", { ["run/.containerenv"] = "", ["etc/machine-id"] = "image-id\n", ["run/host/etc/machine-id"] = "aaaa\n" })
local B = root("hb", { ["run/.containerenv"] = "", ["etc/machine-id"] = "image-id\n", ["run/host/etc/machine-id"] = "bbbb\n" })
local C = root("hc", box)
T:arm("13 IDENTITY two hosts whose toolboxes share a uname -n differ, the id is not printed, and a container with no host id has no bench",
    A ~= B and A ~= "" and not A:find("aaaa", 1, true) and C == "none", "A=" .. A .. " B=" .. B .. " C=" .. C)

-- 14: the writer checks the header too: a foreign count is not carried into ours
local one = (line():gsub("\t2\t5\t", "\t1\t5\t"))
fs.write(W.rel .. "/fsav.tsv", "# preflight-bench v2 some-other-host\n" .. one)
fs.write(W.rel .. "/osav.tsv", HEAD .. one)
save("fsav", "over"); save("osav", "over")
T:arm("14 WRITER a foreign record's count is not carried into this host's (the control's is)",
    benched("fsav") == nil and benched("osav") ~= nil, tostring(benched("fsav")) .. " " .. tostring(benched("osav")))

T:finish()
